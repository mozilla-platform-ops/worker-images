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


def tally(tasks: list[dict], decision_task_id: str) -> dict:
    states = [t["status"]["state"] for t in replicated_tasks(tasks, decision_task_id)]
    return {
        "total": len(states),
        "completed": sum(1 for s in states if s == "completed"),
        "failed": sum(1 for s in states if s == "failed"),
        "exception": sum(1 for s in states if s == "exception"),
        "pending": sum(1 for s in states if s in PENDING_STATES),
        "decision": next(
            (
                t["status"]["state"]
                for t in tasks
                if t["status"]["taskId"] == decision_task_id
            ),
            None,
        ),
    }


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
            run["counts"] = tally(run["tasks"], run["task_group_id"])
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
                    notice(
                        f"  ({elapsed}) {run['pool']}: {c['completed']}/{c['total']} "
                        f"completed, {c['failed']} failed, {c['exception']} exception, "
                        f"{c['pending']} pending/running"
                    )
            last_log = now

        if outstanding == 0:
            return
        time.sleep(TASK_GROUP_POLL_INTERVAL_SECONDS)

    for run in runs:
        if not run.get("done"):
            run["timed_out"] = True


def write_github_summary(runs: list[dict], root_url: str, selection: str = "") -> None:
    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_file:
        return

    lines = ["## HW OS Integration Tests", ""]
    if selection:
        lines += [selection, ""]

    lines += [
        "| Pool | Image | Branch | Revision | Result | Passed | Failed | Exception | Pending |",
        "|---|---|---|---|:---:|:---:|:---:|:---:|:---:|",
    ]
    for run in runs:
        ident = run["identity"]
        c = run.get("counts") or {}
        verdict = run.get("verdict", "not started")
        lines.append(
            "| [{pool}]({url}) | `{image}` | `{branch}` | `{rev}` | {verdict} | "
            "{ok} | {failed} | {exc} | {pending} |".format(
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
            "| Status | Task | State | Duration |",
            "|:---:|---|---|---|",
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
                f"[{name}]({root_url}/tasks/{task_id}) | {status['state']} | {duration} |"
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
        else:
            run["verdict"] = "✅ passed"

    write_github_summary(runs, root_url, selection)

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
