#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "taskcluster",
#     "requests",
#     "pyyaml",
# ]
# ///
"""
Run OS integration tests on MDC1 Windows hardware pools.

Hardware counterpart to ci/run-os-integration.py, kept separate so pool logic
stays off the cloud path. Pools are selected by name, pre-flighted for liveness
and pools.yml agreement, production is refused, and zero tasks is a failure.

Usage:
    uv run ci/run-hw-os-integration.py <pool>[,<pool>...]
    uv run ci/run-hw-os-integration.py win11-64-24h2-hw-relops1213 --no-wait
    uv run ci/run-hw-os-integration.py win11-64-24h2-hw-perf-debug \
        --tests speedometer --repeat 5
    uv run ci/run-hw-os-integration.py --list

Environment variables (required unless --list / --preflight-only):
    TASKCLUSTER_CLIENT_ID      - Taskcluster client ID
    TASKCLUSTER_ACCESS_TOKEN   - Taskcluster access token

Optional:
    TASKCLUSTER_ROOT_URL       - Defaults to https://firefox-ci-tc.services.mozilla.com
    GITHUB_STEP_SUMMARY        - GitHub Actions step summary file (auto-detected)
"""

import argparse
import importlib.util
import json
import os
import re
import statistics
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import requests
import taskcluster

IN_GITHUB_ACTIONS = os.environ.get("GITHUB_ACTIONS") == "true"

HOOK_GROUP_ID = "project-releng"
HOOK_ID = "cron-task-mozilla-platform-ops-worker-images/run-hw-integration-tests"

DECISION_POLL_INTERVAL_SECONDS = 10
# Hardware runs are long: a single speedometer3 task is ~20-40 minutes and a
# small pool serialises them.
DECISION_DISCOVERY_TIMEOUT_SECONDS = 1800
TASK_GROUP_POLL_INTERVAL_SECONDS = 300
TASK_GROUP_LOG_INTERVAL_SECONDS = 600
DEFAULT_TIMEOUT_SECONDS = 6 * 60 * 60

TASK_GROUP_ID_RE = re.compile(r'"taskGroupId":\s*"([A-Za-z0-9_-]{22})"')

REPO_ROOT = Path(__file__).resolve().parent.parent
HW_POOLS_MODULE = (
    REPO_ROOT / "taskcluster" / "worker_images_taskgraph" / "util" / "hw_pools.py"
)


def _load_hw_pools():
    """Load by path: a package import would pull in mozilla_taskgraph."""
    spec = importlib.util.spec_from_file_location("hw_pools", HW_POOLS_MODULE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


hw_pools = _load_hw_pools()


def _escape_github_command_message(message: str) -> str:
    return message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def log(level: str, message: str) -> None:
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    message = f"[{stamp}] {message}"

    # Flush every line: stdout is block-buffered when piped, and without this
    # errors on stderr overtake the stdout context that explains them.
    if IN_GITHUB_ACTIONS and level in ("warning", "error"):
        print(f"::{level}::{_escape_github_command_message(message)}", flush=True)
        return
    if level == "error":
        sys.stdout.flush()
        print(f"ERROR: {message}", file=sys.stderr, flush=True)
    elif level == "warning":
        print(f"WARNING: {message}", flush=True)
    else:
        print(message, flush=True)


def notice(msg):
    log("notice", msg)


def warn(msg):
    log("warning", msg)


def error(msg):
    log("error", msg)


def format_duration(seconds: int) -> str:
    if seconds < 0:
        return "-"
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m {seconds % 60}s"
    return f"{seconds // 3600}h {(seconds % 3600) // 60}m"


def result_emoji(state: str) -> str:
    return {
        "pending": "⏳",
        "running": "⏳",
        "unscheduled": "⏳",
        "completed": "✅",
        "failed": "❌",
        "exception": "⚠️",
    }.get(state, "❓")


# ---- pre-flight ----------------------------------------------------------- #


def preflight(queue, registry, pool, min_healthy: int) -> dict:
    """Check a pool is alive and matches pools.yml; ``ok`` False means skip it.

    The worker list is claim-derived, so a low count usually just means idle; a
    worker pools.yml assigns elsewhere is the real drift signal.
    """
    expected = set(registry.healthy_nodes(pool.name))
    report = {
        "pool": pool.name,
        "identity": pool.identity,
        "expected_nodes": len(expected),
        "ok": True,
        "problems": [],
        "notes": [],
    }

    try:
        data = queue.listWorkers(hw_pools.PROVISIONER_ID, pool.name)
        workers = data.get("workers", []) if isinstance(data, dict) else []
    except taskcluster.exceptions.TaskclusterRestFailure as exc:
        report["ok"] = False
        report["problems"].append(f"could not list workers: {exc}")
        return report

    seen = {w.get("workerId") for w in workers if w.get("workerId")}
    quarantined = {
        w.get("workerId") for w in workers if w.get("quarantineUntil")
    }
    active = seen - quarantined

    report["workers_seen"] = len(seen)
    report["quarantined"] = len(quarantined)
    report["active"] = len(active)

    # Nodes Taskcluster knows about that pools.yml assigns elsewhere.
    foreign = {}
    for worker_id in sorted(active):
        if worker_id in expected:
            continue
        owner = next(
            (n for n, p in registry.pools.items() if worker_id in p.nodes), None
        )
        foreign[worker_id] = owner or "unknown"
    if foreign:
        report["notes"].append(
            "workers active in this queue that pools.yml assigns elsewhere: "
            + ", ".join(f"{w} (pools.yml: {o})" for w, o in foreign.items())
        )

    missing = len(expected) - len(active & expected)
    if missing:
        report["notes"].append(
            f"{missing} of {len(expected)} pools.yml nodes have not claimed work "
            "recently (may simply be idle)"
        )

    if quarantined:
        report["notes"].append(f"{len(quarantined)} worker(s) quarantined")

    if len(active) < min_healthy:
        report["ok"] = False
        report["problems"].append(
            f"only {len(active)} active worker(s), need at least {min_healthy}"
        )

    if pool.is_low_capacity:
        report["notes"].append(
            f"low capacity pool ({pool.node_count} node(s) in pools.yml); the "
            "task graph will serialise"
        )

    try:
        counts = queue.taskQueueCounts(pool.task_queue_id)
        report["pending"] = counts.get("pendingTasks")
        report["claimed"] = counts.get("claimedTasks")
    except taskcluster.exceptions.TaskclusterRestFailure:
        pass

    return report


def print_preflight(report: dict) -> None:
    ident = report["identity"]
    notice(
        f"pre-flight {report['pool']}: "
        f"image={ident['image']} branch={ident['src_branch']} rev={ident['revision']}"
    )
    notice(
        f"  nodes(pools.yml)={report['expected_nodes']} "
        f"active={report.get('active', 0)} quarantined={report.get('quarantined', 0)} "
        f"pending={report.get('pending')} claimed={report.get('claimed')}"
    )
    for note in report["notes"]:
        notice(f"  note: {note}")
    for problem in report["problems"]:
        error(f"  {report['pool']}: {problem}")


# ---- trigger + monitor ---------------------------------------------------- #


def trigger(hooks, pool_name: str, tests: list[str], repeat: int) -> str:
    # One hook fire per pool, so each pool gets its own decision and task group
    # and a slow pool cannot hide another's results.
    payload: dict = {"pools": [pool_name]}
    if tests:
        payload["tests"] = tests
    if repeat > 1:
        payload["repeat"] = repeat
    notice(f"triggering hook for {pool_name}: {json.dumps(payload)}")
    response = hooks.triggerHook(HOOK_GROUP_ID, HOOK_ID, payload)
    return response["taskId"]


def find_task_group(queue, decision_task_id: str, root_url: str) -> str | None:
    """Scrape the task group the decision created; bounded by wall clock."""
    deadline = time.time() + DECISION_DISCOVERY_TIMEOUT_SECONDS
    last_state = None

    while time.time() < deadline:
        try:
            state = queue.status(decision_task_id)["status"]["state"]
            if state != last_state:
                notice(f"  decision task {decision_task_id}: {state}")
                last_state = state

            if state in ("completed", "failed", "exception"):
                artifact = queue.getLatestArtifact(
                    decision_task_id, "public/logs/live_backing.log"
                )
                if isinstance(artifact, dict) and "url" in artifact:
                    resp = requests.get(artifact["url"], timeout=60)
                    for match in TASK_GROUP_ID_RE.findall(resp.text):
                        if match != decision_task_id:
                            return match

                if state != "completed":
                    error(
                        f"  decision task {state}: {root_url}/tasks/{decision_task_id}"
                    )
                    return None
                # Completed but no group id yet: the log may still be flushing.
        except taskcluster.exceptions.TaskclusterRestFailure as exc:
            notice(f"  waiting on decision task artifacts ({exc})")

        time.sleep(DECISION_POLL_INTERVAL_SECONDS)

    error(f"  timed out waiting for decision task {decision_task_id}")
    return None


PENDING_STATES = ("unscheduled", "pending", "running")


def replicated_tasks(tasks: list[dict], decision_task_id: str) -> list[dict]:
    """The group without its root task, which is the decision task itself and
    not a test result. Counting it makes an empty graph look like a run of
    one task and reports a decision failure as a test failure."""
    return [t for t in tasks if t["status"]["taskId"] != decision_task_id]


# A dependency in one of these can still be satisfied. Anything else means a
# task waiting on it will never be scheduled.
DEPENDENCY_DEAD_STATES = ("failed", "exception")


def tally(tasks: list[dict], decision_task_id: str, blocked: set | None = None) -> dict:
    blocked = blocked or set()
    entries = replicated_tasks(tasks, decision_task_id)
    states = [t["status"]["state"] for t in entries]
    return {
        "total": len(states),
        "completed": sum(1 for s in states if s == "completed"),
        "failed": sum(1 for s in states if s == "failed"),
        "exception": sum(1 for s in states if s == "exception"),
        # Blocked tasks are pending as far as Taskcluster is concerned, but
        # waiting on them is waiting on nothing.
        "pending": sum(
            1
            for t in entries
            if t["status"]["state"] in PENDING_STATES
            and t["status"]["taskId"] not in blocked
        ),
        "blocked": sum(1 for t in entries if t["status"]["taskId"] in blocked),
        "decision": next(
            (
                t["status"]["state"]
                for t in tasks
                if t["status"]["taskId"] == decision_task_id
            ),
            None,
        ),
    }


def find_blocked(queue, tasks: list[dict], known: dict) -> dict:
    """Task ids that can never be scheduled, mapped to the upstream that killed
    them.

    A replicated task keeps mozilla-central's concrete dependency ids. The
    decision refuses to create one whose upstream has already failed, but an
    upstream that was still running then can fail afterwards, and the task is
    then `unscheduled` until its deadline -- a day, against a timeout of hours.
    Without this, a run whose every real result is already in still waits out its
    full timeout and then reports one.
    """
    for task in tasks:
        task_id = task["status"]["taskId"]
        if task_id in known or task["status"]["state"] != "unscheduled":
            continue

        dep_ids = task.get("task", {}).get("dependencies") or []
        dead = {}
        for dep_id in dep_ids:
            if dep_id == task_id:
                continue
            try:
                state = queue.status(dep_id)["status"]["state"]
            except taskcluster.exceptions.TaskclusterRestFailure:
                continue
            if state in DEPENDENCY_DEAD_STATES:
                dead[dep_id] = state

        if dead:
            known[task_id] = dead
            name = task.get("task", {}).get("metadata", {}).get("name", task_id)
            detail = ", ".join(f"{d} {s}" for d, s in sorted(dead.items()))
            warn(
                f"  {name} can never be scheduled: upstream {detail}. Not waiting "
                "for it."
            )
    return known


def monitor(queue, runs: list[dict], timeout: int, root_url: str) -> None:
    """Poll every run's task group until all are resolved or the timeout hits."""
    start = time.time()
    last_log = None

    while time.time() - start < timeout:
        outstanding = 0
        for run in runs:
            if run.get("done"):
                continue
            try:
                response = queue.listTaskGroup(run["task_group_id"])
            except taskcluster.exceptions.TaskclusterRestFailure as exc:
                warn(f"  {run['pool']}: error listing task group: {exc}")
                outstanding += 1
                continue

            run["tasks"] = response.get("tasks", [])
            run["blocked"] = find_blocked(
                queue,
                replicated_tasks(run["tasks"], run["task_group_id"]),
                run.get("blocked") or {},
            )
            run["counts"] = tally(
                run["tasks"], run["task_group_id"], set(run["blocked"])
            )
            decision_running = run["counts"]["decision"] in PENDING_STATES
            if run["counts"]["pending"] == 0 and not decision_running:
                run["done"] = True
            else:
                outstanding += 1

        now = time.time()
        if last_log is None or now - last_log >= TASK_GROUP_LOG_INTERVAL_SECONDS:
            elapsed = format_duration(int(now - start))
            for run in runs:
                c = run.get("counts")
                if c:
                    blocked = f", {c['blocked']} blocked" if c.get("blocked") else ""
                    notice(
                        f"  ({elapsed}) {run['pool']}: {c['completed']}/{c['total']} "
                        f"completed, {c['failed']} failed, {c['exception']} exception, "
                        f"{c['pending']} pending/running{blocked}"
                    )
            last_log = now

        if outstanding == 0:
            return
        time.sleep(TASK_GROUP_POLL_INTERVAL_SECONDS)

    for run in runs:
        if not run.get("done"):
            run["timed_out"] = True


# ---- scores --------------------------------------------------------------- #

# Written by every browsertime and talos task; the same numbers Perfherder would
# ingest, before Treeherder gets involved. Reading it here is the whole reason
# this run does not need a Treeherder route: staging-hardware numbers have no
# business in a perf sheriff's view, and the score is right there in the task.
PERFHERDER_ARTIFACT = "public/test_info/perfherder-data.json"


def fetch_perfherder(queue, task_id: str) -> dict | None:
    """Perfherder blob for a task, or None if it did not produce one."""
    try:
        response = queue.getLatestArtifact(task_id, PERFHERDER_ARTIFACT)
    except taskcluster.exceptions.TaskclusterRestFailure:
        return None

    if isinstance(response, dict) and "url" in response:
        try:
            http = requests.get(response["url"], timeout=60)
            http.raise_for_status()
            return http.json()
        except (requests.RequestException, ValueError) as exc:
            warn(f"  could not read {PERFHERDER_ARTIFACT} of {task_id}: {exc}")
            return None
    return response if isinstance(response, dict) else None


def task_worker(task: dict) -> str:
    """The node that produced the result: the last run's worker, since a retry
    can land somewhere else and it is the last run's artifact we read."""
    task_runs = task["status"].get("runs") or []
    return (task_runs[-1].get("workerId") if task_runs else None) or "unknown"


def collect_scores(queue, runs: list[dict]) -> None:
    """Attach each pool's suite scores, keyed by suite name.

    Each sample keeps the node that produced it. On a staging pool that is the
    question behind the numbers: a pool mean hides one bad NUC, and one bad NUC
    is the thing a WIM or ronin change is most likely to have produced.

    Never fatal: a missing or unreadable score does not change whether the tests
    themselves passed.
    """
    for run in runs:
        scores: dict[str, dict] = {}
        for task in replicated_tasks(run.get("tasks") or [], run.get("task_group_id")):
            if task["status"]["state"] != "completed":
                continue
            task_id = task["status"]["taskId"]
            data = fetch_perfherder(queue, task_id)
            if not data:
                continue
            for suite in data.get("suites") or []:
                name = suite.get("name")
                value = suite.get("value")
                if not name or value is None:
                    continue
                entry = scores.setdefault(
                    name,
                    {
                        "unit": suite.get("unit", ""),
                        "lower_is_better": bool(suite.get("lowerIsBetter")),
                        "samples": [],
                    },
                )
                entry["samples"].append(
                    {
                        "worker": task_worker(task),
                        "value": float(value),
                        "task_id": task_id,
                        "replicates": [
                            float(r) for r in (suite.get("replicates") or [])
                        ],
                    }
                )
        if scores:
            run["scores"] = scores


def sample_values(samples: list[dict]) -> list[float]:
    return [sample["value"] for sample in samples]


def by_worker(samples: list[dict]) -> dict[str, list[dict]]:
    grouped: dict[str, list[dict]] = {}
    for sample in samples:
        grouped.setdefault(sample["worker"], []).append(sample)
    return dict(sorted(grouped.items()))


def result_count(run: dict) -> int:
    return sum(len(entry["samples"]) for entry in (run.get("scores") or {}).values())


def idle_nodes(run: dict) -> list[str]:
    """pools.yml nodes that produced no score anywhere in this run.

    Run-level, not per-suite. Taskcluster hands each task to whichever node is
    free, so a node missing from one suite means nothing -- and asking the
    question per suite is what produced forty "no result" rows per suite on a
    run that had one result per suite. A node that claims nothing across a whole
    run is the only version of this worth reading.
    """
    ran = {
        sample["worker"]
        for entry in (run.get("scores") or {}).values()
        for sample in entry["samples"]
    }
    return [node for node in run.get("nodes") or [] if node not in ran]


def idle_note(run: dict) -> str:
    """One line accounting for the nodes the per-worker table cannot show, or ""
    when every node in the pool produced something.

    Idleness is only a signal when there was enough work to reach everyone: an
    os-integration run is one task per test, so most of a 41-node pool sitting
    it out is arithmetic, not a fault. That case gets a count; a run that had at
    least as many results as nodes gets the names, because there a silent node
    means it never claimed its share.
    """
    nodes = run.get("nodes") or []
    idle = idle_nodes(run)
    if not nodes or not idle:
        return ""
    results = result_count(run)
    head = (
        f"{run['pool']}: {len(idle)} of {len(nodes)} pools.yml nodes produced no score"
    )
    if results < len(nodes):
        return (
            f"{head} -- {results} result(s) across {len(nodes)} nodes, so an "
            "uneven split rather than a signal"
        )
    return f"{head} over {results} result(s): " + ", ".join(idle)


def summarize(values: list[float]) -> dict:
    """Mean, median and spread of a sample. Spread is the point of repeating a
    run: a mean nobody can put an error bar on is not a result."""
    summary = {
        "n": len(values),
        "mean": statistics.fmean(values),
        "median": statistics.median(values),
        "min": min(values),
        "max": max(values),
        "stdev": statistics.stdev(values) if len(values) > 1 else 0.0,
    }
    summary["cv"] = 100 * summary["stdev"] / summary["mean"] if summary["mean"] else 0.0
    return summary


# A node this far from its peers is worth looking at rather than averaging away.
# Speedometer3 run-to-run noise on a healthy NUC is ~1-2%, so 5% is well clear of
# it without flagging every pool with an uneven split.
WORKER_OUTLIER_PERCENT = 5.0


def peer_baseline(worker_means: list[float]) -> float:
    """What a node should be compared against: the median of the per-node means.

    Not the pool mean. One slow node drags the pool mean down far enough that
    every healthy node then reads as fast, which flags the whole pool and points
    at nothing. A median of node means is unmoved by a single bad node, so the
    node that is actually different is the one that stands out.
    """
    return statistics.median(worker_means) if worker_means else 0.0


def percent_delta(value: float, baseline: float) -> float:
    return 100 * (value - baseline) / baseline if baseline else 0.0


def is_outlier(delta: float) -> bool:
    return abs(delta) >= WORKER_OUTLIER_PERCENT


def print_scores(runs: list[dict]) -> None:
    for run in runs:
        for name, entry in sorted((run.get("scores") or {}).items()):
            samples = entry["samples"]
            stats = summarize(sample_values(samples))
            direction = (
                "lower is better" if entry["lower_is_better"] else "higher is better"
            )
            notice(
                f"{run['pool']} {name}: mean {stats['mean']:.2f} "
                f"median {stats['median']:.2f} min {stats['min']:.2f} "
                f"max {stats['max']:.2f} stdev {stats['stdev']:.2f} "
                f"({stats['cv']:.1f}% CV over {stats['n']} run(s), "
                f"{entry['unit']}, {direction})"
            )
            grouped = by_worker(samples)
            per_worker = {
                worker: summarize(sample_values(worker_samples))
                for worker, worker_samples in grouped.items()
            }
            baseline = peer_baseline([s["mean"] for s in per_worker.values()])
            for worker, worker_stats in per_worker.items():
                delta = percent_delta(worker_stats["mean"], baseline)
                flag = " OUTLIER" if is_outlier(delta) else ""
                notice(
                    f"  {worker}: mean {worker_stats['mean']:.2f} "
                    f"({delta:+.1f}% vs peers, {worker_stats['cv']:.1f}% CV over "
                    f"{worker_stats['n']} run(s)){flag}"
                )
        note = idle_note(run)
        if note:
            notice(note)


def score_summary_lines(runs: list[dict]) -> list[str]:
    if not any(run.get("scores") for run in runs):
        return []

    lines = [
        "### Scores",
        "",
        "| Pool | Suite | Runs | Mean | Median | Min | Max | Stdev | CV | Unit |",
        "|---|---|:---:|---:|---:|---:|---:|---:|---:|---|",
    ]
    for run in runs:
        for name, entry in sorted((run.get("scores") or {}).items()):
            s = summarize(sample_values(entry["samples"]))
            arrow = "↓" if entry["lower_is_better"] else "↑"
            lines.append(
                f"| {run['pool']} | {name} {arrow} | {s['n']} | {s['mean']:.2f} | "
                f"{s['median']:.2f} | {s['min']:.2f} | {s['max']:.2f} | "
                f"{s['stdev']:.2f} | {s['cv']:.1f}% | {entry['unit']} |"
            )
    lines.append("")

    lines += worker_summary_lines(runs)

    for run in runs:
        for name, entry in sorted((run.get("scores") or {}).items()):
            samples = entry["samples"]
            per_run = ", ".join(f"{s['value']:.2f} ({s['worker']})" for s in samples)
            lines.append(f"- **{run['pool']} {name}** per run: {per_run}")
            replicates = [r for s in samples for r in s["replicates"]]
            if replicates:
                inner = summarize(replicates)
                lines.append(
                    f"  - {inner['n']} in-task replicates, "
                    f"mean {inner['mean']:.2f}, {inner['cv']:.1f}% CV"
                )
    lines.append("")
    lines.append(
        "`↑` higher is better. CV is stdev/mean: the run-to-run noise floor, "
        "which is what a regression has to beat to be real. Δ is a node against "
        "the median of its pool's nodes -- not the pool mean, which one bad node "
        "drags far enough to flag the healthy ones -- and is marked past "
        f"{WORKER_OUTLIER_PERCENT:.0f}%. A row of one run is noise, not a verdict."
    )
    lines.append("")
    return lines


def worker_summary_lines(runs: list[dict]) -> list[str]:
    """Per-node breakdown. A pool mean of three NUCs hides the one that is slow,
    which on staging hardware is usually the thing being looked for.

    Only nodes that produced a result get a row; the rest are accounted for in
    one line per pool by idle_note(), rather than a row per suite each.
    """
    lines = [
        "#### By worker",
        "",
        "| Pool | Worker | Suite | Runs | Mean | Median | Min | Max | CV | Δ vs peers |",
        "|---|---|---|:---:|---:|---:|---:|---:|---:|---:|",
    ]
    flagged = []
    for run in runs:
        for name, entry in sorted((run.get("scores") or {}).items()):
            samples = entry["samples"]
            per_worker = {
                worker: summarize(sample_values(worker_samples))
                for worker, worker_samples in by_worker(samples).items()
            }
            baseline = peer_baseline([s["mean"] for s in per_worker.values()])
            for worker, s in per_worker.items():
                delta = percent_delta(s["mean"], baseline)
                mark = " ⚠️" if is_outlier(delta) else ""
                if is_outlier(delta):
                    flagged.append((run["pool"], worker, name, delta, s["n"]))
                lines.append(
                    f"| {run['pool']} | `{worker}`{mark} | {name} | {s['n']} | "
                    f"{s['mean']:.2f} | {s['median']:.2f} | {s['min']:.2f} | "
                    f"{s['max']:.2f} | {s['cv']:.1f}% | {delta:+.1f}% |"
                )
    lines.append("")

    notes = [f"- {note}" for note in map(idle_note, runs) if note]
    lines += notes

    for pool, worker, suite, delta, count in flagged:
        lines.append(
            f"- ⚠️ **{worker}** ({pool}) is {delta:+.1f}% off its peers on "
            f"{suite} over {count} run(s)"
        )
    if notes or flagged:
        lines.append("")
    return lines


def write_github_summary(runs: list[dict], root_url: str, selection: str = "") -> None:
    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_file:
        return

    lines = ["## HW OS Integration Tests", ""]
    if selection:
        lines += [selection, ""]
    lines += score_summary_lines(runs)

    lines += [
        "| Pool | Image | Branch | Revision | Result | Passed | Failed | "
        "Exception | Blocked | Pending |",
        "|---|---|---|---|:---:|:---:|:---:|:---:|:---:|:---:|",
    ]
    for run in runs:
        ident = run["identity"]
        c = run.get("counts") or {}
        verdict = run.get("verdict", "not started")
        lines.append(
            "| [{pool}]({url}) | `{image}` | `{branch}` | `{rev}` | {verdict} | "
            "{ok} | {failed} | {exc} | {blocked} | {pending} |".format(
                pool=run["pool"],
                url=f"{root_url}/tasks/groups/{run['task_group_id']}"
                if run.get("task_group_id")
                else f"{root_url}/tasks/{run.get('decision_task_id', '')}",
                image=ident.get("image"),
                branch=ident.get("src_branch"),
                rev=ident.get("revision"),
                verdict=verdict,
                ok=c.get("completed", "-"),
                failed=c.get("failed", "-"),
                exc=c.get("exception", "-"),
                blocked=c.get("blocked", "-"),
                pending=c.get("pending", "-"),
            )
        )
    lines.append("")

    for run in runs:
        tasks = replicated_tasks(run.get("tasks") or [], run.get("task_group_id"))
        if not tasks:
            continue
        lines += [
            f"### {run['pool']}",
            "",
            "| Status | Task | Worker | State | Duration |",
            "|:---:|---|---|---|---|",
        ]
        for task in tasks:
            status = task["status"]
            task_id = status["taskId"]
            name = task.get("task", {}).get("metadata", {}).get("name", task_id)
            duration = "-"
            runs_ = status.get("runs") or []
            if runs_:
                started = runs_[-1].get("started")
                resolved = runs_[-1].get("resolved")
                if started and resolved:
                    a = datetime.fromisoformat(started.replace("Z", "+00:00"))
                    b = datetime.fromisoformat(resolved.replace("Z", "+00:00"))
                    duration = format_duration(int((b - a).total_seconds()))
            lines.append(
                f"| {result_emoji(status['state'])} | "
                f"[{name}]({root_url}/tasks/{task_id}) | `{task_worker(task)}` | "
                f"{status['state']} | {duration} |"
            )
        lines.append("")

    Path(summary_file).open("a").write("\n".join(lines))


# --------------------------------------------------------------------------- #


def split_csv(values: list[str]) -> list[str]:
    """Flatten repeated and comma-separated options into a deduped list."""
    items: list[str] = []
    for value in values:
        items.extend(p.strip() for p in value.split(",") if p.strip())
    return list(dict.fromkeys(items))


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run OS integration tests on Windows hardware pools"
    )
    parser.add_argument(
        "pools",
        nargs="*",
        help="Hardware pool name(s) from pools.yml; comma-separated or repeated",
    )
    parser.add_argument(
        "--list", action="store_true", help="List targetable pools and exit"
    )
    parser.add_argument(
        "--preflight-only",
        action="store_true",
        help="Run the pre-flight checks and exit without triggering anything",
    )
    parser.add_argument(
        "--min-healthy-nodes",
        type=int,
        default=1,
        help="Refuse a pool with fewer active workers than this (default: 1)",
    )
    parser.add_argument(
        "--skip-preflight",
        action="store_true",
        help="Trigger without checking pool health (not recommended)",
    )
    parser.add_argument(
        "--tests",
        action="append",
        default=[],
        metavar="SUBSTRING",
        help="Only run tasks whose name contains one of these; "
        "comma-separated or repeated (e.g. --tests speedometer)",
    )
    parser.add_argument(
        "--repeat",
        type=int,
        default=1,
        metavar="N",
        help=f"Run each selected task N times, 1-{hw_pools.MAX_REPEAT} (default: 1)",
    )
    parser.add_argument("--no-wait", action="store_true", help="Exit after triggering")
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_TIMEOUT_SECONDS,
        help=f"Seconds to wait for completion (default: {DEFAULT_TIMEOUT_SECONDS})",
    )
    args = parser.parse_args()

    registry = hw_pools.load_registry(REPO_ROOT)

    if args.list:
        print("Targetable hardware pools:")
        for name, pool in registry.targetable.items():
            print(
                f"  {name:34s} nodes={pool.node_count:3d} "
                f"image={pool.image} branch={pool.src_branch} rev={pool.revision}"
            )
        refused = [n for n, p in registry.pools.items() if p.is_production]
        print("\nProduction (refused): " + ", ".join(refused))
        return 0

    requested = split_csv(args.pools)
    if not requested:
        parser.error("no pools given; use --list to see the targetable pools")

    tests = split_csv(args.tests)
    # Checked here as well as in the decision so a typo costs a second, not a
    # hook fire and a decision task.
    if not 1 <= args.repeat <= hw_pools.MAX_REPEAT:
        parser.error(f"--repeat must be between 1 and {hw_pools.MAX_REPEAT}")

    try:
        pools = registry.resolve(requested)
    except hw_pools.HwPoolError as exc:
        error(str(exc))
        return 2

    os.environ.setdefault(
        "TASKCLUSTER_ROOT_URL", "https://firefox-ci-tc.services.mozilla.com"
    )
    root_url = os.environ["TASKCLUSTER_ROOT_URL"].rstrip("/")

    options = taskcluster.optionsFromEnvironment()
    queue = taskcluster.Queue(options)

    # ---- pre-flight ------------------------------------------------------- #
    if not args.skip_preflight:
        reports = [
            preflight(queue, registry, pool, args.min_healthy_nodes) for pool in pools
        ]
        for report in reports:
            print_preflight(report)
        blocked = [r for r in reports if not r["ok"]]
        if blocked:
            error(
                "pre-flight failed for: " + ", ".join(r["pool"] for r in blocked)
            )
            return 1
        if args.preflight_only:
            notice("pre-flight only: not triggering")
            return 0
    elif args.preflight_only:
        parser.error("--preflight-only and --skip-preflight are mutually exclusive")

    for var in ("TASKCLUSTER_CLIENT_ID", "TASKCLUSTER_ACCESS_TOKEN"):
        if not os.environ.get(var):
            error(f"{var} is not set")
            return 1

    hooks = taskcluster.Hooks(options)

    described = []
    if tests:
        described.append("tasks matching " + ", ".join(f"`{t}`" for t in tests))
    if args.repeat > 1:
        described.append(f"{args.repeat} runs of each")
    selection = "Selection: " + "; ".join(described) if described else ""
    if selection:
        notice(selection.replace("`", ""))

    # ---- trigger ---------------------------------------------------------- #
    runs = []
    for pool in pools:
        decision_task_id = trigger(hooks, pool.name, tests, args.repeat)
        notice(f"  {pool.name}: decision {root_url}/tasks/{decision_task_id}")
        runs.append(
            {
                "pool": pool.name,
                "identity": pool.identity,
                "decision_task_id": decision_task_id,
                # For the by-worker breakdown: a node that claimed nothing all
                # run has no task to be found from.
                "nodes": list(pool.nodes),
            }
        )

    if args.no_wait:
        notice("--no-wait specified, exiting")
        write_github_summary(runs, root_url, selection)
        return 0

    # ---- discover task groups --------------------------------------------- #
    for run in runs:
        group = find_task_group(queue, run["decision_task_id"], root_url)
        if not group:
            run["verdict"] = "⚠️ decision failed"
            continue
        run["task_group_id"] = group
        notice(f"  {run['pool']}: results {root_url}/tasks/groups/{group}")

    live = [r for r in runs if r.get("task_group_id")]
    if not live:
        error("no task groups were created")
        write_github_summary(runs, root_url, selection)
        return 1

    monitor(queue, live, args.timeout, root_url)
    collect_scores(queue, live)

    # ---- verdicts --------------------------------------------------------- #
    failed_overall = False
    for run in runs:
        counts = run.get("counts")
        if run.get("verdict"):
            failed_overall = True
            continue
        if run.get("timed_out"):
            run["verdict"] = "⏳ timed out"
            failed_overall = True
        elif counts and counts["decision"] in ("failed", "exception"):
            # Distinct from an empty graph below: the decision never got as far
            # as deciding, so its log is where the answer is.
            run["verdict"] = "❌ decision failed"
            error(
                f"{run['pool']}: decision task {counts['decision']} -- "
                f"{root_url}/tasks/{run['task_group_id']}"
            )
            failed_overall = True
        elif not counts or counts["total"] == 0:
            # The cloud script calls this a pass; an empty graph means nothing
            # replicated, which is a failure.
            run["verdict"] = "❌ no tasks scheduled"
            error(
                f"{run['pool']}: decision created an empty task group -- nothing "
                "was replicated. Check that mozilla-central scheduled hardware "
                "tasks and that the pool is spelled as in pools.yml."
            )
            failed_overall = True
        elif counts["failed"] or counts["exception"]:
            run["verdict"] = "❌ failed"
            failed_overall = True
        elif counts.get("blocked"):
            # Nothing to do with this image: an upstream mozilla-central task
            # failed, so a copy of a test that depends on it could never run.
            # Reported rather than passed, because the run did not test
            # everything it set out to.
            run["verdict"] = f"⚠️ {counts['blocked']} blocked upstream"
            for task_id, dead in (run.get("blocked") or {}).items():
                upstream = ", ".join(f"{d} {s}" for d, s in sorted(dead.items()))
                warn(
                    f"{run['pool']}: {root_url}/tasks/{task_id} never ran -- "
                    f"upstream {upstream}"
                )
            failed_overall = True
        else:
            run["verdict"] = "✅ passed"

    write_github_summary(runs, root_url, selection)
    print_scores(runs)

    for run in runs:
        counts = run.get("counts") or {}
        notice(
            f"{run['pool']}: {run['verdict']} "
            f"({counts.get('completed', 0)}/{counts.get('total', 0)} completed) "
            f"image={run['identity']['image']} rev={run['identity']['revision']}"
        )

    return 1 if failed_overall else 0


if __name__ == "__main__":
    sys.exit(main())
