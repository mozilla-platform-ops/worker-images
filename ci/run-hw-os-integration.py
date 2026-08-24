#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "taskcluster",
#     "requests",
#     "pyyaml",
#     "anthropic",
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
# GitHub cancels a hosted job at 6h and takes the step summary with it: run
# 31516844982 died that way at 6h00m34s, results and all. So waiting stops at
# 5.75h however long it was asked to wait, leaving a quarter of an hour to read
# the task groups one last time and write the summary. The tasks are never
# cancelled -- Taskcluster carries on and the group keeps the results, which is
# what the summary links to.
WAIT_CEILING_SECONDS = int(5.75 * 60 * 60)

TASK_GROUP_ID_RE = re.compile(r'"taskGroupId":\s*"([A-Za-z0-9_-]{22})"')

# A replicated test task installs the build mozilla-central pointed it at, named
# in EXTRA_MOZHARNESS_CONFIG as a queue artifact URL.
INSTALLER_URL_RE = re.compile(r"/task/([A-Za-z0-9_-]{22})/artifacts/(\S+)$")

REPO_ROOT = Path(__file__).resolve().parent.parent
HW_POOLS_MODULE = (
    REPO_ROOT / "taskcluster" / "worker_images_taskgraph" / "util" / "hw_pools.py"
)


FAILURE_SUMMARY_MODULE = Path(__file__).resolve().parent / "hw_failure_summary.py"


def _load_by_path(name: str, path: Path):
    """Load a sibling module by path: `ci/` is not a package, and a package
    import of hw_pools would pull in mozilla_taskgraph."""
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


hw_pools = _load_by_path("hw_pools", HW_POOLS_MODULE)
hw_failure_summary = _load_by_path("hw_failure_summary", FAILURE_SUMMARY_MODULE)


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


def preflight(
    queue, registry, pool, min_healthy: int, record: dict | None = None
) -> dict:
    """Check a pool is alive and matches pools.yml; ``ok`` False means skip it.

    The worker list is claim-derived, so a low count usually just means idle; a
    worker pools.yml assigns elsewhere is the real drift signal.

    ``record`` carries the pool's configuration from whichever pools.yml is
    authoritative for it -- the deploy branch's, for a pool with `dev:` set.
    """
    record = record or {
        "identity": pool.identity,
        "deployment": pool.deployment,
        "source": "this checkout",
    }
    expected = set(registry.healthy_nodes(pool.name))
    report = {
        "pool": pool.name,
        "identity": record["identity"],
        "deployment": record["deployment"],
        "deployment_source": record["source"],
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
        f"image={ident['image']} branch={ident['src_branch']} rev={ident['revision']} "
        f"(config from {report.get('deployment_source', 'this checkout')})"
    )
    for line in deployment_log_lines(report.get("deployment") or {}):
        notice(f"  {line}")
    notice(
        f"  nodes(pools.yml)={report['expected_nodes']} "
        f"active={report.get('active', 0)} quarantined={report.get('quarantined', 0)} "
        f"pending={report.get('pending')} claimed={report.get('claimed')}"
    )
    for note in report["notes"]:
        notice(f"  note: {note}")
    for problem in report["problems"]:
        error(f"  {report['pool']}: {problem}")


# ---- deployment ----------------------------------------------------------- #

# pools.yml is the only record of what a hardware pool is running -- static
# workers have no worker-manager entry to ask -- so "which configuration did this
# result come from" is answered by these fields and nothing else.
DEPLOYMENT_LABELS = {
    "description": "Pool",
    "image": "WIM image",
    "src_organisation": "Config org",
    "src_repository": "Config repo",
    "src_branch": "Config branch",
    "revision": "Config revision",
    "dev_branch": "Deploy branch (dev)",
    "puppet_version": "Puppet",
    "openvox_version": "OpenVox",
    "git_version": "Git",
    "secret_date": "Secrets",
    "domain_suffix": "Domain",
}

# Drift can also be reported against things that are not pools.yml settings.
DRIFT_LABELS = {**DEPLOYMENT_LABELS, "nodes": "Nodes", "pool": "Pool entry"}

# The table answers "what did this run on" at a glance and stops there: the pool,
# the image, and a link to the config tree. The versions, secret date and domain
# are all read *from* that tree, so the link carries them; they stay in the
# pre-flight log's key=value lines and in drift reporting. dev_branch is left out
# too -- it only ever has a value when the note under the table names it.
SUMMARY_ROWS = {
    "description": "Pool",
    "image": "WIM image",
    # org, repo, branch and revision name one tree; see config_cell().
    "config": "Config",
}

DEFAULT_REPO = "mozilla-platform-ops/worker-images"


def deployment_log_lines(deployment: dict) -> list[str]:
    """The deployment as `key=value` log lines, skipping what pools.yml omits."""
    return [
        f"{key}={value}" for key, value in deployment.items() if value not in (None, "")
    ]


def config_cell(run: dict) -> str | None:
    """org/repo, branch and revision as a single link to the tree that was tested.

    Four rows naming one git tree is three rows more than a reader needs when
    the tree itself can be opened instead.
    """
    deployment = run.get("deployment") or {}
    slug = "/".join(
        part
        for part in (
            deployment.get("src_organisation"),
            deployment.get("src_repository"),
        )
        if part
    )
    text = " @ ".join(part for part in (slug, deployment.get("src_branch")) if part)
    revision = deployment.get("revision")
    if revision:
        text = f"{text} ({revision})" if text else revision
    if not text:
        return None
    url = run.get("config_url")
    return f"[{text}]({url})" if url else f"`{text}`"


def deployment_summary_lines(runs: list[dict]) -> list[str]:
    """A block per pool, so the run says what it ran on without a pools.yml dig."""
    if not any(run.get("deployment") for run in runs):
        return []

    lines = ["### Pool deployment", ""]
    for run in runs:
        deployment = run.get("deployment") or {}
        if not deployment:
            continue
        lines += [
            f"**{run['pool']}**",
            "",
            "| Setting | Value |",
            "|---|---|",
        ]
        for key, label in SUMMARY_ROWS.items():
            if key == "config":
                cell = config_cell(run)
                if cell:
                    lines.append(f"| {label} | {cell} |")
                continue
            value = deployment.get(key)
            if value in (None, ""):
                continue
            rendered = value if key == "description" else f"`{value}`"
            lines.append(f"| {label} | {rendered} |")
        nodes = run.get("nodes") or []
        if nodes:
            lines.append(f"| Nodes | {len(nodes)} (`{nodes[0]}` … `{nodes[-1]}`) |")
        lines.append("")
        lines += deployment_source_lines(run)
    return lines


def deployment_source_lines(run: dict) -> list[str]:
    """Say the pool is on the `dev:` option, and where that option points.

    Only pools with the flag get these lines -- for every other pool this
    checkout is the record, which is the unremarkable case and needs no note.
    """
    dev_branch = (run.get("deployment") or {}).get("dev_branch")
    source = run.get("deployment_source")
    if not dev_branch:
        return []

    link = (
        f"[that branch's `pools.yml`]({pools_yaml_blob_url(this_repo(), dev_branch)})"
    )
    if source == dev_branch:
        body = (
            f"> `{run['pool']}` is on the dev option: `dev: {dev_branch}`, so the "
            f"details above are read from {link}. OS-deploy.ps1 on a dev branch "
            "refreshes pools.yml from the branch, which makes it -- not this "
            "checkout -- the record of what is on the hardware."
        )
    else:
        body = (
            f"> `{run['pool']}` is on the dev option: `dev: {dev_branch}`, so the "
            f"record of what is on the hardware lives in {link}, but it could not "
            "be read. The details above are this checkout's and may lag the "
            "hardware."
        )
    return ["> [!NOTE]", body, ""]


def this_repo() -> str:
    """The repo the workflow is running from, or the canonical one off CI."""
    return os.environ.get("GITHUB_REPOSITORY") or DEFAULT_REPO


def pools_yaml_url(repo: str, ref: str) -> str:
    return (
        f"https://raw.githubusercontent.com/{repo}/{ref}/"
        f"{hw_pools.POOLS_YAML_RELPATH.as_posix()}"
    )


def pools_yaml_blob_url(repo: str, ref: str) -> str:
    """The readable-in-a-browser twin of pools_yaml_url, for links in the summary."""
    return (
        f"https://github.com/{repo}/blob/{ref}/{hw_pools.POOLS_YAML_RELPATH.as_posix()}"
    )


def fetch_registry(repo: str, ref: str):
    """pools.yml as it stands on ``ref`` right now, or None if it cannot be read.

    Never fatal. Failing to check for drift is worth saying out loud, but it is
    not a reason to throw away a run's results.
    """
    url = pools_yaml_url(repo, ref)
    try:
        response = requests.get(url, timeout=60)
        response.raise_for_status()
        return hw_pools.parse_registry(response.text, source=url)
    except (requests.RequestException, hw_pools.HwPoolError, ValueError) as exc:
        warn(f"could not read pools.yml from {ref}: {exc}")
        return None


def deployment_refs(pools, checkout_ref: str) -> list[str]:
    """Every ref whose pools.yml decides one of these pools' configuration."""
    refs = [checkout_ref]
    for pool in pools:
        if pool.dev_branch and pool.dev_branch not in refs:
            refs.append(pool.dev_branch)
    return refs


def deployment_records(pools, checkout_ref: str, snapshot: dict) -> dict[str, dict]:
    """Each pool's configuration, from whichever pools.yml is authoritative for it.

    A pool with `dev:` set is deployed by OS-deploy.ps1 from that branch, and that
    script refreshes pools.yml from the branch -- so for those pools the branch's
    copy is what is on the hardware and this checkout's can lag it. Read the
    branch, fall back to the checkout if it cannot be read, and record which was
    used so the run can say so.

    Node lists stay with the checkout either way: which machines are in a pool is
    bookkeeping this repo's `Known-BAD` map also governs, and pre-flight counts
    against the same list.
    """
    records = {}
    for pool in pools:
        record = {
            "deployment": pool.deployment,
            "identity": pool.identity,
            "config_url": pool.config_url,
            "source": checkout_ref,
        }
        dev_branch = pool.dev_branch
        state = (snapshot.get(dev_branch) or {}).get(pool.name) if dev_branch else None
        if dev_branch and state is None:
            warn(
                f"{pool.name} has dev: {dev_branch}, which is where its deployed "
                "configuration is recorded, but that branch's pools.yml could not "
                "be read; reporting this checkout's values instead"
            )
        elif state is not None:
            # The branch's own copy of the entry carries no `dev:` key, so keep
            # this checkout's -- it is what pointed here in the first place.
            deployment = {**state["deployment"], "dev_branch": dev_branch}
            record.update(
                {
                    "deployment": deployment,
                    "identity": {
                        key: deployment.get(key)
                        for key in ("image", "src_branch", "revision")
                    },
                    "config_url": state.get("config_url"),
                    "source": dev_branch,
                }
            )
            notice(
                f"{pool.name}: dev: {dev_branch} is set, reading its deployed "
                f"configuration from that branch (image={deployment.get('image')} "
                f"branch={deployment.get('src_branch')} "
                f"rev={deployment.get('revision')})"
            )
        records[pool.name] = record
    return records


def snapshot_deployments(pool_names, repo: str, refs: list[str]) -> dict:
    """Per ref, each pool's deployment and node set as that ref records them.

    Taken before the tasks are triggered and again after they finish, and the two
    are compared field by field: pools.yml is a file in a repo that anyone can
    land on mid-run, and a pool that was re-imaged halfway through has produced
    results for two different configurations under one heading.
    """
    snapshot: dict[str, dict] = {}
    for ref in refs:
        registry = fetch_registry(repo, ref)
        if registry is None:
            continue
        per_pool = {}
        for name in pool_names:
            pool = registry.pools.get(name)
            if pool is None:
                continue
            per_pool[name] = {
                "deployment": pool.deployment,
                "config_url": pool.config_url,
                "nodes": tuple(pool.nodes),
            }
        snapshot[ref] = per_pool
    return snapshot


def compare_deployments(before: dict, after: dict) -> list[dict]:
    """Field-level changes between two snapshots, in a stable order."""
    changes = []
    for ref, pools_before in before.items():
        pools_after = after.get(ref)
        if pools_after is None:
            continue
        for pool_name, state_before in pools_before.items():
            state_after = pools_after.get(pool_name)
            if state_after is None:
                changes.append(
                    {
                        "ref": ref,
                        "pool": pool_name,
                        "field": "pool",
                        "before": "present",
                        "after": "removed from pools.yml",
                    }
                )
                continue
            for key in state_before["deployment"]:
                was = state_before["deployment"][key]
                now = state_after["deployment"].get(key)
                if was != now:
                    changes.append(
                        {
                            "ref": ref,
                            "pool": pool_name,
                            "field": key,
                            "before": was,
                            "after": now,
                        }
                    )
            gained = sorted(set(state_after["nodes"]) - set(state_before["nodes"]))
            lost = sorted(set(state_before["nodes"]) - set(state_after["nodes"]))
            if gained or lost:
                moved = []
                if gained:
                    moved.append("added " + ", ".join(gained))
                if lost:
                    moved.append("removed " + ", ".join(lost))
                changes.append(
                    {
                        "ref": ref,
                        "pool": pool_name,
                        "field": "nodes",
                        "before": f"{len(state_before['nodes'])} node(s)",
                        "after": "; ".join(moved),
                    }
                )
    return changes


def report_drift(changes: list[dict]) -> None:
    for change in changes:
        label = DRIFT_LABELS.get(change["field"], change["field"])
        warn(
            f"CONFIGURATION CHANGED MID-RUN -- {change['pool']} {label} on "
            f"{change['ref']}: {change['before']!r} -> {change['after']!r}. "
            "Results before and after the change are not the same experiment."
        )


def drift_summary_lines(changes: list[dict]) -> list[str]:
    """A caution block at the top of the summary, where it cannot be missed."""
    if not changes:
        return []
    lines = [
        "> [!CAUTION]",
        (
            "> **The pool configuration changed while this run was in flight.** "
            "pools.yml was edited between triggering these tasks and their "
            "results, so the numbers below may span two different configurations "
            "and are not attributable to one. Check when each task ran against "
            "when the change landed before trusting anything here."
        ),
        "",
        "| Pool | Setting | Ref | Before | After |",
        "|---|---|---|---|---|",
    ]
    for change in changes:
        label = DRIFT_LABELS.get(change["field"], change["field"])
        lines.append(
            f"| {change['pool']} | {label} | `{change['ref']}` | "
            f"`{change['before']}` | `{change['after']}` |"
        )
    lines.append("")
    return lines


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


def elapsed_since_run_start(now: datetime | None = None) -> float:
    """Seconds the workflow run has already burned, or 0.0 if it cannot be told.

    The 6h clock GitHub is watching started before this script did -- checkout,
    uv, pre-flight -- so the wait is budgeted from the run, not from here, where
    the workflow passes the run's start time.
    """
    stamp = os.environ.get("GITHUB_RUN_STARTED_AT")
    if not stamp:
        return 0.0
    try:
        started = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        warn(f"cannot read GITHUB_RUN_STARTED_AT={stamp!r}; budgeting from now")
        return 0.0
    return max(((now or datetime.now(timezone.utc)) - started).total_seconds(), 0.0)


def wait_budget(
    requested: int, elapsed: float = 0.0, in_actions: bool | None = None
) -> int:
    """The requested wait, trimmed to what fits before the runner is cancelled.

    Only in Actions: the ceiling exists because GitHub cancels the job, and a
    local run has nobody to answer to.
    """
    if not (IN_GITHUB_ACTIONS if in_actions is None else in_actions):
        return requested
    remaining = max(WAIT_CEILING_SECONDS - int(elapsed), 0)
    if requested <= remaining:
        return requested
    notice(
        f"waiting {format_duration(remaining)} rather than the requested "
        f"{format_duration(requested)}: GitHub cancels this job at "
        f"{format_duration(6 * 60 * 60)} and the summary goes with it. Tasks still "
        "running then are left to Taskcluster, not cancelled."
    )
    return remaining


def refresh_run(queue, run: dict) -> bool:
    """Re-read one run's task group. True when nothing of it is outstanding."""
    try:
        response = queue.listTaskGroup(run["task_group_id"])
    except taskcluster.exceptions.TaskclusterRestFailure as exc:
        warn(f"  {run['pool']}: error listing task group: {exc}")
        return False

    run["tasks"] = response.get("tasks", [])
    run["blocked"] = find_blocked(
        queue,
        replicated_tasks(run["tasks"], run["task_group_id"]),
        run.get("blocked") or {},
    )
    run["counts"] = tally(run["tasks"], run["task_group_id"], set(run["blocked"]))
    decision_running = run["counts"]["decision"] in PENDING_STATES
    if run["counts"]["pending"] == 0 and not decision_running:
        run["done"] = True
    return bool(run.get("done"))


def monitor(queue, runs: list[dict], timeout: int, root_url: str) -> None:
    """Poll every run's task group until all are resolved or the timeout hits."""
    start = time.time()
    last_log = None

    while time.time() - start < timeout:
        outstanding = 0
        for run in runs:
            if run.get("done"):
                continue
            if not refresh_run(queue, run):
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

    # The wait is over; the tasks are not. Read every group once more so the
    # summary reports everything that landed -- the last poll can be five minutes
    # stale -- then leave them running. Cancelling would throw away hardware time
    # that is about to produce a result, and the group keeps it either way.
    waited = int(time.time() - start)
    for run in runs:
        if run.get("done"):
            continue
        refresh_run(queue, run)
        if not run.get("done"):
            run["timed_out"] = True
            run["waited"] = waited
            counts = run.get("counts") or {}
            warn(
                f"  {run['pool']}: still running after {format_duration(waited)} "
                f"({counts.get('pending', '?')} task(s) outstanding). Not cancelling "
                f"them: {root_url}/tasks/groups/{run['task_group_id']}"
            )


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


def task_name(task: dict) -> str:
    return (
        task.get("task", {}).get("metadata", {}).get("name", task["status"]["taskId"])
    )


def short_pool(pool: str) -> str:
    """The part of a pool name that differs between pools.

    Every hardware pool is `win11-64-24h2-hw-<something>`. The full name is one
    row up in the verdict table, so the family prefix on every task row is width
    spent to say what the reader already knows.
    """
    return pool.split("-hw-", 1)[-1] if "-hw-" in pool else pool


def short_task(name: str, pool: str) -> str:
    """A replicated task name without the parts its pool already fixes.

    `gecko-hw-<pool>-test-<platform>/opt-mochitest-media-mda-gpu` is ~100
    characters of which only the tail varies within a pool. The platform is
    reported once per pool by `task_platform`, so it comes off here rather than
    being repeated on every row.
    """
    trimmed = name.removeprefix(f"gecko-hw-{pool}-")
    if "/" not in trimmed:
        return trimmed
    suffix = trimmed.split("/", 1)[1]
    for build_type in ("opt-", "debug-"):
        if suffix.startswith(build_type):
            return suffix.removeprefix(build_type)
    return suffix


def task_platform(tasks: list[dict], pool: str) -> str:
    """The gecko test platform a pool's tasks were replicated from.

    A pool stages exactly one worker type, so every task it runs carries the
    same platform -- and which one it is, `-hw-ref-shippable` against plain
    `-shippable`, is the difference between the reference pool and the rest.
    Reported per pool because that is the granularity it varies at.
    """
    for task in tasks:
        trimmed = (
            task_name(task).removeprefix(f"gecko-hw-{pool}-").removeprefix("test-")
        )
        if "/" in trimmed:
            platform, _, suffix = trimmed.partition("/")
            return f"{platform}/{suffix.split('-', 1)[0]}"
    return "-"


def task_seconds(task: dict) -> int | None:
    """Wall time of the last run, or None if it has not resolved."""
    task_runs = task["status"].get("runs") or []
    if not task_runs:
        return None
    started, resolved = task_runs[-1].get("started"), task_runs[-1].get("resolved")
    if not (started and resolved):
        return None
    a = datetime.fromisoformat(started.replace("Z", "+00:00"))
    b = datetime.fromisoformat(resolved.replace("Z", "+00:00"))
    return int((b - a).total_seconds())


# Worst first. Unresolved sorts above green because it is the row that decides
# whether the run is finished; an unrecognised state sorts last but is still
# named in the table rather than dropped.
_STATE_ORDER = {
    "failed": 0,
    "exception": 1,
    "pending": 2,
    "running": 2,
    "unscheduled": 2,
    "completed": 3,
}


def builds_under_test(tasks: list[dict]) -> list[dict]:
    """The Firefox builds a pool's replicated tasks actually installed.

    Nothing here is built by this repo. A replicated task keeps
    mozilla-central's own `installer_url`, so what it tests is whatever build
    that task pointed at -- and not necessarily one build per pool: a
    custom-car run carries a plain `build-win64/opt` alongside the shippable
    one every other task uses.

    The gecko revision is the part worth recording. The graph is replicated from
    a floating index, so which revision a run tested is a property of when it
    ran, not of anything in this repo, and it is not otherwise written down.
    """
    found: dict[tuple, int] = {}
    for task in tasks:
        env = (task.get("task", {}).get("payload") or {}).get("env") or {}
        try:
            config = json.loads(env.get("EXTRA_MOZHARNESS_CONFIG") or "{}")
        except ValueError:
            continue
        match = INSTALLER_URL_RE.search(config.get("installer_url") or "")
        if not match:
            continue
        key = (
            env.get("GECKO_HEAD_REPOSITORY", ""),
            env.get("GECKO_HEAD_REV", ""),
            match.group(1),
            match.group(2),
            # Verbatim, not rebuilt from the parts: this is the exact string
            # mozilla-central handed the task, and it is what you would curl to
            # get the same bits the hardware installed.
            config["installer_url"],
        )
        found[key] = found.get(key, 0) + 1

    return [
        {
            "repository": repository,
            "revision": revision,
            "task_id": task_id,
            "artifact": artifact,
            "url": url,
            "tasks": count,
        }
        # Most-used build first: the one-off variants are the footnote.
        for (repository, revision, task_id, artifact, url), count in sorted(
            found.items(), key=lambda item: (-item[1], item[0])
        )
    ]


def build_metadata(queue, task_id: str, artifact: str) -> dict:
    """Name the build, and date it.

    Three questions the task id alone does not answer: what kind of build it is,
    when it was produced -- which is how stale the thing under test was, and the
    graph is replicated from a floating index so it is never today by default --
    and when the artifact goes away, which is what #878 exists to work around.

    Never fatal, and each field independently so one failure does not cost the
    others: an unnamed, undated build is still an identified one.
    """
    metadata = {"name": "", "built": "", "expires": "", "size": 0}
    try:
        definition = queue.task(task_id)
        metadata["name"] = (definition.get("metadata") or {}).get("name", "")
    except Exception as exc:  # noqa: BLE001 - a name is not worth failing a run
        warn(f"could not read build task {task_id}: {exc}")
    try:
        task_runs = (queue.status(task_id).get("status") or {}).get("runs") or []
        metadata["built"] = task_runs[-1].get("resolved", "") if task_runs else ""
    except Exception as exc:  # noqa: BLE001
        warn(f"could not read build task status {task_id}: {exc}")
    try:
        for entry in queue.listLatestArtifacts(task_id).get("artifacts") or []:
            if entry.get("name") == artifact:
                metadata["expires"] = entry.get("expires", "")
                metadata["size"] = entry.get("contentLength", 0)
                break
    except Exception as exc:  # noqa: BLE001
        warn(f"could not list artifacts of build task {task_id}: {exc}")
    return metadata


def collect_builds(queue, runs: list[dict]) -> None:
    """Attach each pool's builds, each described well enough to go and fetch."""
    known: dict[tuple, dict] = {}
    for run in runs:
        builds = builds_under_test(
            replicated_tasks(run.get("tasks") or [], run.get("task_group_id"))
        )
        for build in builds:
            key = (build["task_id"], build["artifact"])
            if key not in known:
                known[key] = build_metadata(queue, *key)
            build.update(known[key])
        run["builds"] = builds


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


# There is deliberately no node-against-node comparison here. These pools are two
# and three nodes: the median of two node means is the midpoint between them, so
# both nodes are always equidistant from it and either both are flagged or
# neither is. Run 32743362153 produced six such flags and every one was an
# artifact of that -- ±100% between a node scoring 0.00 dropped frames and one
# scoring 0.48, on a suite where near-zero is the good answer. A pool this small
# has no peer group, only the other node, so each node is reported on its own
# terms: its mean, its spread, and how many runs it is drawn from.


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
            for worker, worker_stats in per_worker.items():
                notice(
                    f"  {worker}: mean {worker_stats['mean']:.2f} "
                    f"({worker_stats['cv']:.1f}% CV over "
                    f"{worker_stats['n']} run(s))"
                )
        note = idle_note(run)
        if note:
            notice(note)


def score_summary_lines(runs: list[dict]) -> list[str]:
    """The headline number per pool and suite, and nothing else.

    The per-node breakdown and the per-run replicates are a different question
    -- "is one of these NUCs slow", not "what did the pool score" -- and they
    are three times the length. They live in score_detail_lines() at the foot of
    the summary, where looking for them is a deliberate act.
    """
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
    return lines


def score_detail_lines(runs: list[dict]) -> list[str]:
    """Per-node and per-replicate scores, at the foot of the summary.

    Everything here answers a question you have to already be asking: which node
    is slow, how noisy was the sample, which pools.yml nodes never scored at
    all. Above the results it is a wall of numbers between the reader and the
    verdict; below them it is the detail they came back for.
    """
    if not any(run.get("scores") for run in runs):
        return []

    lines = ["### Score detail", ""]

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
        "which is what a regression has to beat to be real. Nodes are not "
        "compared against each other -- with two or three of them the "
        "comparison says more about the arithmetic than the hardware -- so read "
        "each node's own CV instead. A row of one run is noise, not a verdict."
    )
    lines.append("")
    return lines


def worker_summary_lines(runs: list[dict]) -> list[str]:
    """Per-node breakdown: what each node scored and how much it moved.

    Each node on its own terms, with no node-against-node verdict -- see the
    note above print_scores(). CV is the column to read: a node whose own runs
    disagree is the finding, and unlike a delta it means the same thing whether
    the pool has two nodes or ten.

    Only nodes that produced a result get a row; the rest are accounted for in
    one line per pool by idle_note(), rather than a row per suite each.
    """
    lines = [
        "#### By worker",
        "",
        "| Pool | Worker | Suite | Runs | Mean | Median | Min | Max | CV |",
        "|---|---|---|:---:|---:|---:|---:|---:|---:|",
    ]
    for run in runs:
        for name, entry in sorted((run.get("scores") or {}).items()):
            per_worker = {
                worker: summarize(sample_values(worker_samples))
                for worker, worker_samples in by_worker(entry["samples"]).items()
            }
            for worker, s in per_worker.items():
                lines.append(
                    f"| {run['pool']} | `{worker}` | {name} | {s['n']} | "
                    f"{s['mean']:.2f} | {s['median']:.2f} | {s['min']:.2f} | "
                    f"{s['max']:.2f} | {s['cv']:.1f}% |"
                )
    lines.append("")

    notes = [f"- {note}" for note in map(idle_note, runs) if note]
    if notes:
        lines += notes + [""]
    return lines


def outran_wait_lines(runs: list[dict], root_url: str) -> list[str]:
    """Say the wait ran out before the tasks did, and where they carried on.

    The counts under such a block are a snapshot rather than a total, and this run
    is not where the rest will appear -- the task group is.
    """
    late = [run for run in runs if run.get("timed_out")]
    if not late:
        return []

    waited = max(run.get("waited") or 0 for run in late)
    lines = [
        "> [!WARNING]",
        f"> These tasks ran longer than the {format_duration(waited)} this run "
        "waited for them, so the counts below are what had landed by then, not the "
        "whole answer. Nothing was cancelled -- the tasks are still running in "
        "Taskcluster and their group keeps every result:",
        ">",
    ]
    for run in late:
        counts = run.get("counts") or {}
        group = run["task_group_id"]
        lines.append(
            f"> - `{run['pool']}` — {counts.get('completed', 0)}/"
            f"{counts.get('total', 0)} completed, {counts.get('pending', 0)} still "
            f"running: [`{group}`]({root_url}/tasks/groups/{group})"
        )
    lines.append("")
    return lines


def classify_run(run: dict) -> tuple:
    """(verdict, inconclusive reason, is this the hardware's fault).

    Only the third field decides the exit code, and only a task that ran on the
    hardware and did not pass sets it. Everything else -- an empty graph, a
    failed decision, an upstream that could never resolve, a wait that ran out
    -- reached no verdict about the image, and failing the run for those trains
    people to skim exactly the red that matters.
    """
    if run.get("verdict"):
        # Set at trigger time: the hook fired but no decision came back.
        return run["verdict"], "the decision never produced a task group", False

    counts = run.get("counts")
    if run.get("timed_out"):
        return (
            "⏳ ran past the wait",
            "the wait ran out while tasks were still running",
            False,
        )
    if counts and counts["decision"] in ("failed", "exception"):
        # Distinct from an empty graph: the decision never got as far as
        # deciding, so its log is where the answer is.
        return (
            "⚠️ decision failed",
            f"the decision task {counts['decision']}",
            False,
        )
    if not counts or counts["total"] == 0:
        return (
            "⚠️ no tasks scheduled",
            "nothing was replicated onto the pool",
            False,
        )
    if counts["failed"] or counts["exception"]:
        return "❌ failed", None, True
    if counts.get("blocked"):
        # Nothing to do with this image: an upstream mozilla-central task
        # failed, so a copy of a test that depends on it could never run.
        return (
            f"⚠️ {counts['blocked']} blocked upstream",
            f"{counts['blocked']} task(s) could never be scheduled",
            False,
        )
    return "✅ passed", None, False


def log_verdict_detail(run: dict, root_url: str) -> None:
    """The pointer a reader needs for the verdict they just got."""
    counts = run.get("counts") or {}
    verdict = run.get("verdict", "")
    if verdict == "⚠️ decision failed":
        warn(
            f"{run['pool']}: decision task {counts.get('decision')} -- "
            f"{root_url}/tasks/{run.get('task_group_id')}"
        )
    elif verdict == "⚠️ no tasks scheduled":
        warn(
            f"{run['pool']}: decision created an empty task group -- nothing was "
            "replicated. Check that mozilla-central scheduled hardware tasks and "
            "that the pool is spelled as in pools.yml."
        )
    elif verdict.endswith("blocked upstream"):
        for task_id, dead in (run.get("blocked") or {}).items():
            upstream = ", ".join(f"{d} {s}" for d, s in sorted(dead.items()))
            warn(
                f"{run['pool']}: {root_url}/tasks/{task_id} never ran -- "
                f"upstream {upstream}"
            )


def inconclusive_lines(inconclusive: list[tuple]) -> list[str]:
    """Say a green run proved nothing, where the reader is looking at the green.

    A run that never got a task onto the hardware is not a pass, but it is not
    the image's fault either -- and failing it teaches people that red means
    "mozilla-central had a bad day", which is exactly the habit that makes a
    real regression easy to skim past.
    """
    if not inconclusive:
        return []
    lines = [
        "> [!IMPORTANT]",
        (
            "> This run is green because nothing failed on the hardware -- not "
            "because the image passed. No verdict was reached for:"
        ),
        ">",
    ]
    for pool, reason in inconclusive:
        lines.append(f"> - `{pool}` — {reason}")
    lines += [
        ">",
        (
            "> Re-run it once the cause above is resolved; nothing here says "
            "anything about the image under test."
        ),
        "",
    ]
    return lines


def results_table_lines(runs: list[dict], root_url: str) -> list[str]:
    """Every task from every pool in one table, worst first.

    One table rather than a section per pool: with more than one pool selected
    the reader is comparing them, and what they compare is which task failed
    where -- a question that two tables separated by a screen of scores answers
    badly. Sorted by state and then by wall time, so the row that decides the
    verdict is the first one, and a green run still leads with its slowest task.
    """
    rows = [
        (run, task)
        for run in runs
        for task in replicated_tasks(run.get("tasks") or [], run.get("task_group_id"))
    ]
    if not rows:
        return []

    rows.sort(
        key=lambda row: (
            _STATE_ORDER.get(row[1]["status"]["state"], len(_STATE_ORDER)),
            -(task_seconds(row[1]) or 0),
        )
    )

    lines = [
        "### Results",
        "",
        "|  | Pool | Task | Worker | Duration |",
        "|:---:|---|---|---|---:|",
    ]
    for run, task in rows:
        state = task["status"]["state"]
        seconds = task_seconds(task)
        # The emoji carries every state `result_emoji` knows, which is why there
        # is no State column; a state it does not know is named instead of lost.
        label = short_task(task_name(task), run["pool"])
        if state not in _STATE_ORDER:
            label = f"{label} ({state})"
        lines.append(
            f"| {result_emoji(state)} | {short_pool(run['pool'])} | "
            f"[{label}]({root_url}/tasks/{task['status']['taskId']}) | "
            f"`{task_worker(task)}` | "
            f"{format_duration(seconds) if seconds is not None else '-'} |"
        )
    lines.append("")
    return lines


def pool_mapping_lines(runs: list[dict]) -> list[str]:
    """What each pool is standing in for, before any of its results.

    A staging pool is only meaningful as a stand-in: `-perf-debug` takes the
    tasks mozilla-central schedules on `win11-64-24h2-hw`, `-ref-alpha` takes
    the ones it schedules on `win11-64-24h2-hw-ref`. Those are different suites
    on different hardware, so which one a reader is looking at decides what the
    numbers below can be compared with -- and until now it was implicit in the
    pool name and the task-name prefix, neither of which says it.

    The gecko platform comes off the replicated tasks themselves rather than the
    pool name, so it also says whether the pool got what its counterpart runs.
    """
    if not runs:
        return []

    lines = [
        "### Pool mapping",
        "",
        "| Pool | Stages | Gecko platform | Nodes |",
        "|---|---|---|:---:|",
    ]
    for run in runs:
        platform = task_platform(run.get("tasks") or [], run["pool"])
        lines.append(
            f"| `{run['pool']}` | `{run.get('stages') or '-'}` | "
            f"`{platform}` | {len(run.get('nodes') or []) or '-'} |"
        )
    lines += [
        "",
        (
            "Both sides are `releng-hardware` worker types: the pool the tasks "
            "ran on, and the production one they were replicated from."
        ),
        "",
    ]
    return lines


def stamp(iso: str | None) -> str:
    """`2026-08-21T17:35:25.163Z` as `2026-08-21 17:35Z`. Minutes are as fine as
    anyone reads a build date to, and seconds cost a column's width."""
    if not iso or "T" not in iso:
        return ""
    date, _, rest = iso.partition("T")
    return f"{date} {rest[:5]}Z"


def revision_url(repository: str, revision: str) -> str:
    if not repository or not revision:
        return ""
    stem = repository.rstrip("/")
    return f"{stem}/{'commit' if 'github.com' in stem else 'rev'}/{revision}"


def build_summary_lines(runs: list[dict], root_url: str) -> list[str]:
    """What each pool actually installed, and from which revision.

    The run reports the worker image it tested to the commit, and until now said
    nothing at all about the other half -- the Firefox build the tests ran. A
    red run is only attributable to an image once you know the build under it
    did not also move, and the index this graph is replicated from floats.
    """
    rows = [(run, build) for run in runs for build in (run.get("builds") or [])]
    if not rows:
        return []

    lines = [
        "### Build under test",
        "",
        "| Pool | Gecko revision | Build task | Built | Artifact expires | Tasks |",
        "|---|---|---|---|---|:---:|",
    ]
    for run, build in rows:
        revision = build.get("revision") or ""
        url = revision_url(build.get("repository", ""), revision)
        shown = revision[:12] or "unknown"
        lines.append(
            f"| {short_pool(run['pool'])} | "
            f"{f'[`{shown}`]({url})' if url else f'`{shown}`'} | "
            f"[{build.get('name') or build['task_id']}]"
            f"({root_url}/tasks/{build['task_id']}) | "
            f"{stamp(build.get('built')) or '-'} | "
            f"{stamp(build.get('expires')) or '-'} | {build['tasks']} |"
        )

    # The URL in full and on its own line rather than behind link text: it is
    # the one thing here you might want to curl, and a table cell mangles it.
    lines += ["", "The exact artifact each pool installed:", "", "```"]
    for run, build in rows:
        size = build.get("size") or 0
        lines.append(
            f"{short_pool(run['pool'])}{f'  ({size / 1e6:.0f} MB)' if size else ''}"
        )
        lines.append(f"  {build.get('url') or '(no installer_url)'}")
    lines += ["```", ""]

    lines += [
        (
            "Nothing above is built by this repo: a replicated task installs "
            "whatever build mozilla-central's own `installer_url` pointed at. "
            "The revision comes from the index the graph was replicated from, "
            "which floats -- two runs a day apart can test different revisions, "
            "and a red run is only the image's fault if this row held still. "
            "**Built** is when that build finished, not when this run started: "
            "the gap between them is how stale the thing under test was."
        ),
        "",
    ]
    return lines


def write_github_summary(
    runs: list[dict],
    root_url: str,
    selection: str = "",
    drift: list[dict] | None = None,
    failure_summary: list[str] | None = None,
    inconclusive: list[tuple] | None = None,
) -> None:
    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_file:
        return

    lines = ["## HW OS Integration Tests", ""]
    # First: what each pool is a stand-in for. It is four lines, it never
    # changes mid-run, and it decides how everything below it reads.
    lines += pool_mapping_lines(runs)
    # Then a run whose configuration moved, which is not a result at all and
    # which nobody should have to scroll to find out about.
    lines += drift_summary_lines(drift or [])
    # Then, for the same reason: counts that are a snapshot rather than a total.
    lines += outran_wait_lines(runs, root_url)
    # And then why a green run may not be a pass.
    lines += inconclusive_lines(inconclusive or [])
    if selection:
        lines += [selection, ""]

    # Then the results, before anything that analyses them: what ran, where, and
    # whether it passed.
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
            "| [{pool}]({url}) | `{image}` | `{branch}` | `{rev}` | "
            "{verdict} | {ok} | {failed} | {exc} | {blocked} | {pending} |".format(
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

    # Which pool went red, then which task did it, then why. The per-task detail
    # used to sit at the bottom under the deployment tables, which put a screen
    # of configuration between a red verdict and the name of the thing that
    # failed.
    lines += results_table_lines(runs, root_url)

    # Straight after the results: what those results were a test of.
    lines += build_summary_lines(runs, root_url)

    lines += failure_summary or []

    # The numbers come after the thing they are numbers about, and only the
    # headline: one row per pool and suite.
    lines += score_summary_lines(runs)

    lines += deployment_summary_lines(runs)

    # Last, because it is the longest section and the least often wanted: the
    # per-node breakdown, the idle-node accounting and the per-run replicates.
    lines += score_detail_lines(runs)

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
        help=f"Seconds to wait for completion (default: {DEFAULT_TIMEOUT_SECONDS}; "
        f"in GitHub Actions, capped at {WAIT_CEILING_SECONDS} so the summary is "
        "written before the job is cancelled)",
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

    # ---- what is on the hardware ------------------------------------------ #
    # Resolved before pre-flight so its log names the deployed configuration, and
    # kept to be re-read once the tasks have resolved.
    repo = this_repo()
    checkout_ref = os.environ.get("GITHUB_REF_NAME") or "main"
    refs = deployment_refs(pools, checkout_ref)
    pool_names = [pool.name for pool in pools]
    before = snapshot_deployments(pool_names, repo, refs)
    records = deployment_records(pools, checkout_ref, before)

    # ---- pre-flight ------------------------------------------------------- #
    if not args.skip_preflight:
        reports = [
            preflight(queue, registry, pool, args.min_healthy_nodes, records[pool.name])
            for pool in pools
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
        record = records[pool.name]
        decision_task_id = trigger(hooks, pool.name, tests, args.repeat)
        notice(f"  {pool.name}: decision {root_url}/tasks/{decision_task_id}")
        runs.append(
            {
                "pool": pool.name,
                "identity": record["identity"],
                "deployment": record["deployment"],
                "deployment_source": record["source"],
                "config_url": record["config_url"],
                "decision_task_id": decision_task_id,
                # What this pool is standing in for: the production worker type
                # whose mozilla-central tasks get replicated onto it.
                "stages": pool.source_worker_type,
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

    monitor(queue, live, wait_budget(args.timeout, elapsed_since_run_start()), root_url)
    # Scores for whatever resolved, timed out or not: a run that ran out of wait
    # still has results, and they are the reason it was started.
    collect_scores(queue, live)
    # Which Firefox build each pool installed. Recorded in the log as well as
    # the summary: the summary dies with the job if GitHub cancels it at 6h.
    collect_builds(queue, live)
    for run in live:
        for build in run.get("builds") or []:
            notice(
                f"  {run['pool']}: build under test "
                f"{build.get('name') or build['task_id']} "
                f"gecko {build['revision'][:12] or 'unknown'} "
                f"built {stamp(build.get('built')) or 'unknown'} "
                f"for {build['tasks']} task(s)"
            )
            notice(f"    {build.get('url') or '(no installer_url)'}")

    # ---- did the configuration move under us? ----------------------------- #
    drift = compare_deployments(before, snapshot_deployments(pool_names, repo, refs))
    report_drift(drift)

    # ---- verdicts --------------------------------------------------------- #
    failed_overall = False
    inconclusive = []
    for run in runs:
        verdict, reason, failed = classify_run(run)
        run["verdict"] = verdict
        if failed:
            failed_overall = True
        elif reason:
            inconclusive.append((run["pool"], reason))
        log_verdict_detail(run, root_url)

    # Only a red run pays for this, and only after the verdict is decided: it
    # explains the failures the reader is already looking at. An inconclusive
    # run has no failing task to read -- nothing ran -- so it makes no call.
    failure_summary = []
    if failed_overall:
        failure_summary, _ = hw_failure_summary.build(
            queue, runs, replicated_tasks, drift, root_url, warn
        )

    write_github_summary(
        runs, root_url, selection, drift, failure_summary, inconclusive
    )
    print_scores(runs)

    for run in runs:
        counts = run.get("counts") or {}
        notice(
            f"{run['pool']}: {run['verdict']} "
            f"({counts.get('completed', 0)}/{counts.get('total', 0)} completed) "
            f"image={run['identity']['image']} rev={run['identity']['revision']}"
        )

    if drift:
        # Last line of the log as well as the first block of the summary: the
        # verdict above means less than the fact that it moved.
        error(
            f"{len(drift)} configuration change(s) landed while this run was in "
            "flight; the results are not attributable to one configuration"
        )

    if failed_overall:
        return 1

    # Green, but not a pass: nothing ran on the hardware that could have told us
    # anything. Red is reserved for a task that ran and did not pass, because a
    # red that means "mozilla-central had a bad day" teaches people to skim the
    # red that means "this image is broken". The warnings above are the record.
    for pool, reason in inconclusive:
        warn(f"{pool}: inconclusive -- {reason}. This says nothing about the image.")
    if inconclusive:
        notice(
            "run is green because nothing failed on the hardware, but "
            f"{len(inconclusive)} pool(s) produced no verdict -- see the summary."
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
