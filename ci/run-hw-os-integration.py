#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "taskcluster",
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
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import taskcluster

IN_GITHUB_ACTIONS = os.environ.get("GITHUB_ACTIONS") == "true"

HOOK_GROUP_ID = "project-releng"
HOOK_ID = "cron-task-mozilla-platform-ops-worker-images/run-hw-integration-tests"

# Hardware runs are long: a single speedometer3 task is ~20-40 minutes and a
# small pool serialises them.
TASK_GROUP_POLL_INTERVAL_SECONDS = 300
TASK_GROUP_LOG_INTERVAL_SECONDS = 600
DEFAULT_TIMEOUT_SECONDS = 6 * 60 * 60

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
    quarantined = {w.get("workerId") for w in workers if w.get("quarantineUntil")}
    queue_active = seen - quarantined
    active = queue_active & expected

    report["workers_seen"] = len(seen)
    report["quarantined"] = len(quarantined)
    report["active"] = len(active)
    report["queue_active"] = len(queue_active)

    # Refuse nodes that pools.yml marks as bad or assigns to another pool.
    unsafe = {}
    for worker_id in sorted(queue_active - expected):
        if worker_id in registry.known_bad_nodes:
            unsafe[worker_id] = "known bad"
            continue
        owner = next(
            (n for n, p in registry.pools.items() if worker_id in p.nodes), None
        )
        unsafe[worker_id] = f"pools.yml: {owner or 'unknown'}"
    if unsafe:
        report["ok"] = False
        report["problems"].append(
            "unsafe worker(s) active in this queue: "
            + ", ".join(f"{w} ({reason})" for w, reason in unsafe.items())
        )

    missing = len(expected - active)
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
        f"declared-image={ident['image']} declared-branch={ident['src_branch']} "
        f"declared-rev={ident['revision']}"
    )
    notice(
        f"  nodes(pools.yml)={report['expected_nodes']} "
        f"active(expected)={report.get('active', 0)} "
        f"active(queue)={report.get('queue_active', 0)} "
        f"quarantined={report.get('quarantined', 0)} "
        f"pending={report.get('pending')} claimed={report.get('claimed')}"
    )
    for note in report["notes"]:
        notice(f"  note: {note}")
    for problem in report["problems"]:
        error(f"  {report['pool']}: {problem}")


# ---- trigger + monitor ---------------------------------------------------- #


def trigger(hooks, pool_name: str) -> str:
    payload = {"pools": [pool_name]}
    notice(f"triggering hook for {pool_name}: {json.dumps(payload)}")
    response = hooks.triggerHook(HOOK_GROUP_ID, HOOK_ID, payload)
    return response["taskId"]


def tally(tasks: list[dict]) -> dict:
    states = [t["status"]["state"] for t in tasks]
    return {
        "total": len(states),
        "completed": sum(1 for s in states if s == "completed"),
        "failed": sum(1 for s in states if s == "failed"),
        "exception": sum(1 for s in states if s == "exception"),
        "pending": sum(1 for s in states if s in ("pending", "running", "unscheduled")),
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
            decision = next(
                (
                    task
                    for task in run["tasks"]
                    if task["status"]["taskId"] == run["decision_task_id"]
                ),
                None,
            )
            run["tasks"] = [
                task
                for task in run["tasks"]
                if task["status"]["taskId"] != run["decision_task_id"]
            ]
            run["counts"] = tally(run["tasks"])
            decision_state = decision and decision["status"]["state"]
            if decision_state in ("failed", "exception"):
                run["decision_failed"] = decision_state
                run["done"] = True
            elif decision_state == "completed" and run["counts"]["pending"] == 0:
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


def unexpected_workers(tasks: list[dict], expected: set[str]) -> set[str]:
    return {
        run["workerId"]
        for task in tasks
        for run in task["status"].get("runs", [])
        if run.get("workerId") and run["workerId"] not in expected
    }


def write_github_summary(runs: list[dict], root_url: str) -> None:
    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_file:
        return

    lines = ["## HW OS Integration Tests", ""]

    lines += [
        "Task completion does not validate performance. Review the Perfherder data before production.",
        "",
        "| Pool | Declared image | Declared branch | Declared revision | Result | Completed | Failed | Exception | Pending |",
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
        if not run.get("tasks"):
            continue
        lines += [
            f"### {run['pool']}",
            "",
            "| Status | Task | State | Duration |",
            "|:---:|---|---|---|",
        ]
        for task in run["tasks"]:
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

    with Path(summary_file).open("a") as summary:
        summary.write("\n".join(lines))


# --------------------------------------------------------------------------- #


def parse_pools(values: list[str]) -> list[str]:
    names: list[str] = []
    for value in values:
        names.extend(p.strip() for p in value.split(",") if p.strip())
    return list(dict.fromkeys(names))


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

    requested = parse_pools(args.pools)
    if not requested:
        parser.error("no pools given; use --list to see the targetable pools")

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
            error("pre-flight failed for: " + ", ".join(r["pool"] for r in blocked))
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

    # ---- trigger ---------------------------------------------------------- #
    runs = []
    for pool in pools:
        decision_task_id = trigger(hooks, pool.name)
        notice(f"  {pool.name}: decision {root_url}/tasks/{decision_task_id}")
        runs.append(
            {
                "pool": pool.name,
                "identity": pool.identity,
                "decision_task_id": decision_task_id,
                "task_group_id": decision_task_id,
                "expected_workers": set(registry.healthy_nodes(pool.name)),
            }
        )

    if args.no_wait:
        notice("--no-wait specified, exiting")
        write_github_summary(runs, root_url)
        return 0

    for run in runs:
        notice(
            f"  {run['pool']}: results {root_url}/tasks/groups/{run['task_group_id']}"
        )

    monitor(queue, runs, args.timeout, root_url)

    # ---- verdicts --------------------------------------------------------- #
    failed_overall = False
    for run in runs:
        counts = run.get("counts")
        if decision_state := run.get("decision_failed"):
            run["verdict"] = f"❌ decision {decision_state}"
            failed_overall = True
        elif run.get("timed_out"):
            run["verdict"] = "⏳ timed out"
            failed_overall = True
        elif not counts or counts["total"] == 0:
            # The cloud script calls this a pass; an empty graph means nothing
            # replicated, which is a failure.
            run["verdict"] = "❌ no tasks scheduled"
            error(
                f"{run['pool']}: decision created an empty task group -- nothing "
                "was replicated. Check that autoland scheduled tier 1 hardware "
                "tasks and that the pool is spelled as in pools.yml."
            )
            failed_overall = True
        elif counts["failed"] or counts["exception"]:
            run["verdict"] = "❌ failed"
            failed_overall = True
        elif unexpected := unexpected_workers(run["tasks"], run["expected_workers"]):
            run["verdict"] = "❌ unexpected worker"
            error(
                f"{run['pool']}: task ran on worker(s) outside pools.yml: "
                + ", ".join(sorted(unexpected))
            )
            failed_overall = True
        else:
            run["verdict"] = "⚠️ tasks completed; review performance"
            warn(
                f"{run['pool']}: tasks completed, but performance was not "
                "evaluated. Review Perfherder data before production."
            )

    write_github_summary(runs, root_url)

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
