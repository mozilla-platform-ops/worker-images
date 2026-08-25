# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

"""Replicate mozilla-central's Windows hardware test tasks onto MDC1 HW pools.

Not built on mozilla_taskgraph's replicate transform: that discards every
releng-hardware task before consulting config, and bumping it would affect the
cloud integration-test kind. Namespaced away from the cloud path throughout.

A pool only ever receives the tasks of the production pool it stages, matched by
worker type: `win11-64-24h2-hw-alpha` runs what `win11-64-24h2-hw` runs, and
`win11-64-24h2-hw-ref-alpha` runs what `win11-64-24h2-hw-ref` runs. Those are
different suites on different hardware models, so replicating both onto both
would report failures that only mean the task was on the wrong machine.
"""

import json
import logging
import os
import re
from collections import defaultdict
from copy import deepcopy
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests
from taskgraph.transforms.base import TransformSequence
from taskgraph.util.taskcluster import (
    find_task_id,
    get_artifact,
    get_task_definition,
    status_task_batched,
)

from worker_images_taskgraph.util.hw_pools import (
    MAX_REPEAT,
    HwPoolError,
    load_registry,
)

logger = logging.getLogger(__name__)
transforms = TransformSequence()

# Replaced wholesale: the source tasks carry mozilla-central's own index and
# treeherder routes, which a retargeted run must not write to.
KEPT_ROUTES: list[str] = []

# Matches `gecko-level-3` and friends, as mozilla_taskgraph's replicate does, so
# cache names and the scopes that hold them are rewritten the same way.
_LEVEL_RE = re.compile(r"[a-z]+-level-[1-3]")

_CACHE_SCOPE_PREFIX = "generic-worker:cache:"
_OS_GROUP_SCOPE_PREFIX = "generic-worker:os-group:"

# A dependency in any of these has not resolved yet, and waiting on it is
# correct. Anything else means the replicated task can never be scheduled.
_DEPENDENCY_OK_STATES = frozenset({"completed", "unscheduled", "pending", "running"})

_STATUS_BATCH_SIZE = 200

# How many names to print before truncating a "nothing matched" listing.
_MAX_LISTED_NAMES = 25


def _repo_root(config) -> Path:
    root_dir = getattr(config.graph_config, "root_dir", None)
    if root_dir:
        candidate = Path(root_dir).parent
        if (candidate / "provisioners").is_dir():
            return candidate
    from worker_images_taskgraph.util.hw_pools import find_repo_root

    return find_repo_root()


class HwUpstreamError(HwPoolError):
    """Every candidate task for a pool has a dead upstream.

    Distinct from the other refusals because it is the one that another graph
    might not have: the same tasks from an earlier push depend on that push's
    own build. See _earlier_push_source.
    """


def _fetch_source_tasks(index: str, provisioner: str) -> dict:
    """A decision graph's hardware tasks by worker type, plus its label index.

    The labels are kept because a replicated task's fetches name task ids, and
    an expired one can only be re-resolved by asking a fresher graph for the
    same label -- see _repair_fetches.
    """
    return _fetch_decision_tasks(find_task_id(index), provisioner, index)


def _fetch_decision_tasks(decision_task_id: str, provisioner: str, label: str) -> dict:
    """As _fetch_source_tasks, for a decision task already in hand."""
    task_graph = get_artifact(decision_task_id, "public/task-graph.json")

    # public/task-graph.json is keyed by task id, with the label inside each
    # entry -- which is what makes an expired fetch re-resolvable by label.
    by_worker_type = defaultdict(list)
    labels = {}
    for task_id, task_def in sorted(task_graph.items()):
        labels[task_id] = task_def.get("label", task_id)
        task = task_def.get("task", {})
        if task.get("provisionerId") != provisioner:
            continue
        task_def.setdefault("label", task_id)
        by_worker_type[task["workerType"]].append(task_def)

    logger.info(
        f"hw-integration: {label} (decision {decision_task_id}) has "
        f"{sum(len(v) for v in by_worker_type.values())} {provisioner} task(s) "
        f"across {len(by_worker_type)} worker type(s)"
    )
    return {
        "by_worker_type": dict(by_worker_type),
        "labels": labels,
        "decision": decision_task_id,
    }


def _drop_uncurated_kinds(source_tasks, pool, index: str, drop_kinds) -> list:
    """Trim a fall-back index to the kinds a curated one would have carried.

    The first target is mozilla-central's own os-integration set: whatever it
    holds for a pool is the answer, taken whole. Every target after it is a full
    tier-1 push, which for a pool os-integration does not cover means every task
    the counterpart runs -- for `win11-64-24h2-hw-ref` on 2026-08-19 that was 16
    tasks and 10.6h of maxRunTime across two nodes, twelve of them the `ml-*`
    perftest suite. os-integration names two perftests for the whole tree,
    `service-worker` and `startup-geckoview`, and no ML ones, so dropping the
    kind here follows that curation rather than inventing a rule of our own.
    """
    if not drop_kinds:
        return source_tasks

    dropped = [source for source in source_tasks if source.get("kind") in drop_kinds]
    if not dropped:
        return source_tasks

    kept = [source for source in source_tasks if source.get("kind") not in drop_kinds]
    kinds = ", ".join(sorted(drop_kinds))
    if not kept:
        raise HwPoolError(
            f"hw-integration: {pool.name} stages {pool.source_worker_type}, and "
            f"every task {index} schedules on it is of kind {kinds}, which is "
            "dropped from an uncurated index. Nothing would run."
        )

    logger.info(
        f"hw-integration: {pool.name}: {index} is not a curated set, so "
        f"{len(dropped)} {kinds} task(s) were dropped and {len(kept)} kept: "
        f"{_listed(_source_name(s) for s in dropped)}"
    )
    return kept


def _curate(source_tasks, pool, index: str, curated) -> list:
    """Trim an uncurated index to the set this repo has chosen for the pool.

    mozilla-central's test_configs/os-integration.yml names no set for
    `win11-64-24h2-hw-ref`, and we do not change that tree, so the choice has to
    live here. Without it the set is whatever a tier-1 push happens to schedule
    on the platform -- 16 tasks on 2026-08-19, 21 on 2026-08-24 -- which nobody
    picked and which moves whenever the tree does.

    Entries are matched as substrings, as the `--tests` filter is, so
    `speedometer3` also selects `speedometer3-no-nv`. An entry that matches
    nothing is a warning rather than an error: mozilla-central renaming a task
    should not take a whole run down with it.
    """
    wanted = [name for name in (curated.get(pool.source_worker_type) or []) if name]
    if not wanted:
        return source_tasks

    kept, matched = [], set()
    for source in source_tasks:
        name = _source_name(source).lower()
        hits = [w for w in wanted if w.lower() in name]
        if hits:
            kept.append(source)
            matched.update(hits)

    for missing in sorted(set(wanted) - matched):
        logger.warning(
            f"hw-integration: {pool.name}: curated entry {missing!r} matched no "
            f"task in {index}. It may have been renamed or removed in-tree."
        )

    if not kept:
        raise HwPoolError(
            f"hw-integration: {pool.name}: none of the curated tasks "
            f"({', '.join(wanted)}) are scheduled by {index}. Its "
            f"{len(source_tasks)} available task(s): "
            f"{_listed(_source_name(s) for s in source_tasks)}"
        )

    logger.info(
        f"hw-integration: {pool.name}: {index} is not a curated set, so it was "
        f"trimmed to the {len(kept)} task(s) this repo names for "
        f"{pool.source_worker_type}: {_listed(_source_name(s) for s in kept)}"
    )
    return kept


def _sources_for_pool(
    pool, targets: list[str], provisioner: str, cache: dict, drop_kinds=(), curated=None
):
    """Tasks for the pool's counterpart, from the first target index that has any.

    Ordered rather than merged: the os-integration index carries a curated set
    sized for a small pool, and the push decision -- the only index that
    schedules `-hw-ref` tasks -- carries a full tier-1 run's worth, which is why
    everything after the first index is trimmed by _drop_uncurated_kinds.
    Fetching is lazy so selecting only `-hw` pools never downloads the larger
    graph.
    """
    seen_worker_types = set()

    for position, index in enumerate(targets):
        if index not in cache:
            cache[index] = _fetch_source_tasks(index, provisioner)
        by_worker_type = cache[index]["by_worker_type"]
        seen_worker_types.update(by_worker_type)

        if matched := by_worker_type.get(pool.source_worker_type):
            if position:
                matched = _drop_uncurated_kinds(matched, pool, index, drop_kinds)
                matched = _curate(matched, pool, index, curated or {})
            logger.info(
                f"hw-integration: {pool.name} <- {len(matched)} "
                f"{provisioner}/{pool.source_worker_type} task(s) from {index}"
            )
            return matched, index

    raise HwPoolError(
        f"hw-integration: {pool.name} stages {provisioner}/"
        f"{pool.source_worker_type}, and no such task is scheduled by any of "
        f"{', '.join(targets)}. Worker types found there: "
        f"{', '.join(sorted(seen_worker_types)) or 'none'}"
    )


def _source_name(source) -> str:
    return source["task"]["metadata"]["name"]


def _listed(names) -> str:
    names = sorted(names)
    shown = ", ".join(names[:_MAX_LISTED_NAMES])
    if len(names) > _MAX_LISTED_NAMES:
        shown += f", ... and {len(names) - _MAX_LISTED_NAMES} more"
    return shown


def _select_tests(source_tasks, filters, pool):
    """Keep the tasks whose name contains any of ``filters``.

    Substring rather than glob or regex: the filter is typed into a workflow
    field, and `speedometer` is what someone means to type.
    """
    if not filters:
        return source_tasks

    lowered = [f.lower() for f in filters]
    matched = [
        source
        for source in source_tasks
        if any(f in _source_name(source).lower() for f in lowered)
    ]
    if not matched:
        raise HwPoolError(
            f"hw-integration: nothing on {pool.name} matches "
            f"{', '.join(filters)}. Its {len(source_tasks)} available task(s): "
            f"{_listed(_source_name(s) for s in source_tasks)}"
        )

    logger.info(
        f"hw-integration: {pool.name}: {len(matched)} of {len(source_tasks)} "
        f"task(s) match {', '.join(filters)}: "
        f"{_listed(_source_name(s) for s in matched)}"
    )
    return matched


def _dependency_states(dep_ids: list[str]) -> dict[str, str]:
    states = {}
    for start in range(0, len(dep_ids), _STATUS_BATCH_SIZE):
        batch = dep_ids[start : start + _STATUS_BATCH_SIZE]
        for task_id, status in (status_task_batched(batch) or {}).items():
            states[task_id] = status.get("state", "unknown")
    return states


# ---- expired fetches ------------------------------------------------------ #

# A replicated task keeps mozilla-central's concrete fetch task ids, and
# MOZ_FETCHES can only name a task and an artifact -- fetch-content builds the
# URL from those two fields, so there is no way to point it at a plain URL.
# Re-pointing it at a *different task* is therefore the only repair available.
#
# It is needed because the Chrome-for-Testing fetches carry `cached_task: false`
# in mozilla-central: every graph builds its own copy and the artifact lives two
# days, because the thing it wraps changes daily. Against a weekly
# os-integration cron that is a guaranteed miss for most of the week -- on
# 2026-08-19 `cft-cd-win64-canary.tar.bz2` had expired ten hours before the run
# started, and browsertime-benchmark-custom-car-speedometer3 spent eight minutes
# of hardware time collecting HTTP 410s before failing.
FETCHES_ENV = "MOZ_FETCHES"

# An artifact that expires while the run is still queuing is as good as gone:
# hardware runs sit for hours behind a build.
FETCH_EXPIRY_MARGIN = timedelta(hours=6)


def _root_url() -> str:
    return os.environ.get(
        "TASKCLUSTER_ROOT_URL", "https://firefox-ci-tc.services.mozilla.com"
    ).rstrip("/")


def _artifact_expiries(task_id: str) -> dict:
    """Each artifact of a task and when it expires. Empty if it cannot be read."""
    url = f"{_root_url()}/api/queue/v1/task/{task_id}/artifacts"
    try:
        response = requests.get(url, timeout=60)
        response.raise_for_status()
        artifacts = response.json().get("artifacts", [])
    except (requests.RequestException, ValueError) as exc:
        logger.warning(f"hw-integration: could not list artifacts of {task_id}: {exc}")
        return {}

    expiries = {}
    for artifact in artifacts:
        stamp = artifact.get("expires")
        if not stamp:
            continue
        try:
            expiries[artifact["name"]] = datetime.fromisoformat(
                stamp.replace("Z", "+00:00")
            )
        except ValueError:
            continue
    return expiries


def _fetch_is_live(task_id: str, artifact: str, cache: dict, now) -> bool:
    if task_id not in cache:
        cache[task_id] = _artifact_expiries(task_id)
    expires = cache[task_id].get(artifact)
    return expires is not None and expires > now + FETCH_EXPIRY_MARGIN


def _live_replacement(label, artifact, indexes, graphs, artifacts, now):
    """The same fetch, from whichever fresher graph still has it."""
    for index in indexes:
        if index not in graphs:
            try:
                decision = find_task_id(index)
                graphs[index] = get_artifact(decision, "public/label-to-taskid.json")
            except Exception as exc:  # noqa: BLE001 -- one missing index is not fatal
                logger.warning(f"hw-integration: could not read {index}: {exc}")
                graphs[index] = {}
        candidate = graphs[index].get(label)
        if candidate and _fetch_is_live(candidate, artifact, artifacts, now):
            return candidate, index
    return None, None


def _repair_fetches(source_tasks, pool, labels, indexes):
    """Re-point expired fetches at a live copy; drop what cannot be repaired.

    Substitution is deliberately loud. The replacement is a *newer build* of the
    same thing -- for a Chrome-for-Testing canary that is what "canary" means,
    but it is not the byte-for-byte artifact the source graph pinned, and the
    log has to say so.
    """
    now = datetime.now(timezone.utc)
    artifacts: dict[str, dict] = {}
    graphs: dict[str, dict] = {}

    runnable, unrepairable = [], {}
    for source in source_tasks:
        env = source["task"].get("payload", {}).get("env", {})
        raw = env.get(FETCHES_ENV)
        if not raw:
            runnable.append(source)
            continue
        try:
            fetches = json.loads(raw)
        except ValueError:
            runnable.append(source)
            continue

        name = _source_name(source)
        substitutions, dead = [], []
        for fetch in fetches:
            task_id, artifact = fetch.get("task"), fetch.get("artifact")
            if not task_id or not artifact:
                continue
            if _fetch_is_live(task_id, artifact, artifacts, now):
                continue

            label = labels.get(task_id)
            replacement, index = (
                _live_replacement(label, artifact, indexes, graphs, artifacts, now)
                if label
                else (None, None)
            )
            if not replacement:
                dead.append(f"{artifact} (task {task_id}, label {label or 'unknown'})")
                continue

            expires = artifacts[replacement][artifact]
            logger.warning(
                f"hw-integration: {name}: {artifact} has expired on task "
                f"{task_id}; using {replacement} from {index} instead, which "
                f"expires {expires.isoformat()}. This is a newer build of the "
                "same artifact, not the one the source graph pinned."
            )
            substitutions.append(
                {
                    "artifact": artifact,
                    "expired_task": task_id,
                    "replacement_task": replacement,
                    "source_index": index,
                }
            )
            fetch["task"] = replacement

        if dead:
            unrepairable[name] = dead
            continue

        if substitutions:
            env[FETCHES_ENV] = json.dumps(fetches)
            dependencies = source["task"].get("dependencies") or []
            for change in substitutions:
                # The dependency has to move with the fetch: waiting on a task
                # whose artifact is gone is waiting for nothing.
                dependencies = [
                    change["replacement_task"] if dep == change["expired_task"] else dep
                    for dep in dependencies
                ]
            source["task"]["dependencies"] = list(dict.fromkeys(dependencies))
            source["task"].setdefault("extra", {}).setdefault("hw-integration", {})[
                "substituted-fetches"
            ] = substitutions

        runnable.append(source)

    for name, dead in sorted(unrepairable.items()):
        logger.warning(
            f"hw-integration: skipping {name} on {pool.name}: no live copy of "
            f"{', '.join(dead)}. Running it would spend the hardware time and "
            "then fail on an HTTP 410."
        )

    if not runnable:
        raise HwPoolError(
            f"hw-integration: every selected task for {pool.name} needs a fetch "
            f"artifact that has expired with no live copy: {_listed(unrepairable)}"
        )
    return runnable


def _drop_blocked(source_tasks, pool):
    """Drop tasks an already-failed upstream leaves unschedulable.

    A replicated task keeps mozilla-central's concrete dependency task ids, so a
    toolchain that failed in the source graph means the copy sits `unscheduled`
    until its deadline -- turning an otherwise good run into a timeout with no
    result. Seen on the first green run: `toolchain-win64-custom-car` had failed,
    so `browsertime-benchmark-custom-car-speedometer3` never started.
    """
    dep_ids = sorted(
        {
            dep
            for source in source_tasks
            for dep in source["task"].get("dependencies", [])
        }
    )
    if not dep_ids:
        return source_tasks

    states = _dependency_states(dep_ids)
    runnable, blocked = [], {}
    for source in source_tasks:
        broken = {
            dep: states.get(dep, "unknown")
            for dep in source["task"].get("dependencies", [])
            if states.get(dep, "unknown") not in _DEPENDENCY_OK_STATES
        }
        if broken:
            blocked[_source_name(source)] = broken
        else:
            runnable.append(source)

    for name, broken in sorted(blocked.items()):
        detail = ", ".join(f"{dep} {state}" for dep, state in sorted(broken.items()))
        logger.warning(
            f"hw-integration: skipping {name} on {pool.name}: upstream {detail}. "
            "It could never be scheduled, and waiting on it would time the run out."
        )

    if not runnable:
        raise HwUpstreamError(
            f"hw-integration: every selected task for {pool.name} depends on a "
            f"mozilla-central task that failed: {_listed(blocked)}"
        )
    return runnable


# `index.gecko.v2.mozilla-central.pushlog-id.45154.decision` -> prefix and 45154.
_PUSHLOG_ROUTE_RE = re.compile(
    r"^index\.(?P<prefix>.+)\.pushlog-id\.(?P<push>\d+)\.decision$"
)

# How many pushes back to look, and how many ids to scan getting there. Not every
# id resolves to an indexed decision -- 45160 does not, while 45161 and 45162 do
# -- so the walk skips gaps rather than assuming the ids are contiguous.
_WALKBACK_SCAN_MULTIPLIER = 4


def _earlier_pushes(decision_task_id: str, limit: int) -> list[tuple[int, str]]:
    """(push id, decision task id) for the pushes before this one, newest first.

    Only a push decision carries a pushlog-id route, so a curated cron graph
    yields nothing here and never walks -- which is right: its build finished
    long ago, and an older cron graph is a week older, not a push older.
    """
    if limit < 1:
        return []
    try:
        routes = get_task_definition(decision_task_id).get("routes") or []
    except Exception as exc:  # noqa: BLE001 - no walk is worse than no run
        logger.warning(f"hw-integration: could not read {decision_task_id}: {exc}")
        return []

    for route in routes:
        if match := _PUSHLOG_ROUTE_RE.match(route):
            prefix, newest = match["prefix"], int(match["push"])
            break
    else:
        return []

    found: list[tuple[int, str]] = []
    for push in range(
        newest - 1, max(newest - 1 - limit * _WALKBACK_SCAN_MULTIPLIER, 0), -1
    ):
        if len(found) == limit:
            break
        try:
            found.append((push, find_task_id(f"{prefix}.pushlog-id.{push}.decision")))
        except Exception:  # noqa: BLE001,S112 - a gap in the pushlog is normal
            continue
    return found


def _earlier_push_source(
    pool, decision_task_id, provisioner, cache, drop_kinds, curated, limit, tried
):
    """The same pool's tasks from the most recent earlier push that has any.

    A push whose build was cancelled leaves every replicated task unschedulable
    -- run 32768047542 died that way, on a `build-win64-shippable/opt` cancelled
    23 minutes after its own decision. The push before it had a completed build,
    so the run was recoverable and simply was not recovered. Taken as a whole
    graph rather than by repointing the build, so the test task and the build it
    installs still come from one push.
    """
    if not decision_task_id:
        return None, None
    for push, earlier in _earlier_pushes(decision_task_id, limit):
        label = f"pushlog-id {push}"
        # A graph already refused cannot become runnable by being asked again,
        # and without this the walk can be handed the same push forever.
        if label in tried:
            continue
        if label not in cache:
            cache[label] = _fetch_decision_tasks(earlier, provisioner, label)
        matched = cache[label]["by_worker_type"].get(pool.source_worker_type)
        if not matched:
            continue
        logger.warning(
            f"hw-integration: {pool.name}: falling back to push {push} "
            f"(decision {earlier}); the newer push's tasks all had a dead upstream"
        )
        matched = _drop_uncurated_kinds(matched, pool, label, drop_kinds)
        return label, _curate(matched, pool, label, curated)
    return None, None


def _log_runtime_budget(pool, source_tasks, repeat):
    """Worst-case hardware time, so the decision log says what a run will cost
    before the caller's timeout has to discover it."""
    budget = (
        sum(
            source["task"].get("payload", {}).get("maxRunTime", 0)
            for source in source_tasks
        )
        * repeat
    )
    if not budget:
        return
    hours = budget / 3600
    per_node = f", ~{hours / pool.node_count:.1f}h across {pool.node_count} node(s)"
    times = f" x{repeat} run(s)" if repeat > 1 else ""
    logger.info(
        f"hw-integration: {pool.name}: {len(source_tasks)} task(s){times}, "
        f"{hours:.1f}h of maxRunTime worst case"
        f"{per_node if pool.node_count else ''}"
    )


def _rewrite_scopes(task, old_pool: str, new_pool: str, level_repl: str):
    """Keep holdable scopes, retarget pool-bound, drop the rest: an unholdable
    scope fails task creation, a dropped one only affects its own task."""
    kept, dropped = [], []
    for scope in task.get("scopes", []):
        if scope.startswith(_CACHE_SCOPE_PREFIX):
            kept.append(_LEVEL_RE.sub(level_repl, scope))
        elif scope.startswith(_OS_GROUP_SCOPE_PREFIX):
            kept.append(scope.replace(old_pool, new_pool))
        else:
            dropped.append(scope)

    if dropped:
        logger.info(
            "hw-integration: dropped un-holdable scope(s) from "
            f"{task['metadata']['name']}: {', '.join(sorted(dropped))}"
        )
    task["scopes"] = kept


def _rewrite_caches(task, level_repl: str):
    payload = task.get("payload", {})

    if cache := payload.get("cache"):
        payload["cache"] = {_LEVEL_RE.sub(level_repl, k): v for k, v in cache.items()}

    for mount in payload.get("mounts", []):
        if "cacheName" in mount:
            mount["cacheName"] = _LEVEL_RE.sub(level_repl, mount["cacheName"])


def _rewrite_datestamps(task):
    """Absolute datestamps from a completed task cannot be resubmitted."""
    task["created"] = {"relative-datestamp": "0 seconds"}
    task["deadline"] = {"relative-datestamp": "1 day"}
    task["expires"] = {"relative-datestamp": "1 month"}

    artifacts = task.get("payload", {}).get("artifacts")
    if artifacts:
        entries = artifacts.values() if isinstance(artifacts, dict) else artifacts
        for artifact in entries:
            if "expires" in artifact:
                artifact["expires"] = {"relative-datestamp": "1 month"}


@transforms.add
def replicate_onto_hw_pools(config, tasks):
    requested = list(config.params.get("hw_pools") or [])

    for task in tasks:
        replicate_config = task.pop("hw-replicate")

        # Ordinary push/PR decision: emit nothing and make no network calls.
        if not requested:
            logger.debug(
                f"hw-integration: no hw_pools requested, skipping {config.kind}"
            )
            continue

        registry = load_registry(_repo_root(config))
        try:
            pools = registry.resolve(requested)
        except HwPoolError as exc:
            raise HwPoolError(f"hw-integration: {exc}") from exc

        provisioner = replicate_config["provisioner"]
        targets = list(replicate_config["targets"])
        drop_kinds = frozenset(replicate_config.get("fallback-drop-kinds") or ())
        curated = dict(replicate_config.get("fallback-tests") or {})
        walkback = replicate_config.get("blocked-walkback") or 0
        repair_indexes = list(replicate_config.get("fetch-repair-targets") or ())
        source_cache: dict[str, dict] = {}

        test_filters = [f for f in (config.params.get("hw_tests") or []) if f]
        # Unset means once; anything else is taken at face value, so `0` is a
        # mistake to report rather than a synonym for the default.
        repeat = config.params.get("hw_repeat")
        repeat = 1 if repeat is None else repeat
        if (
            isinstance(repeat, bool)
            or not isinstance(repeat, int)
            or not 1 <= repeat <= MAX_REPEAT
        ):
            raise HwPoolError(
                f"hw-integration: repeat must be a whole number between 1 and "
                f"{MAX_REPEAT}, got {repeat!r}"
            )

        trust_domain = config.graph_config["trust-domain"]
        level = config.params["level"]
        scheduler_id = f"{trust_domain}-level-{level}"

        for pool in pools:
            logger.info(
                f"hw-integration: targeting {pool.task_queue_id} "
                f"(image={pool.image} branch={pool.src_branch} rev={pool.revision} "
                f"nodes={pool.node_count})"
            )
            if pool.is_low_capacity:
                logger.warning(
                    f"hw-integration: {pool.name} has only {pool.node_count} "
                    "node(s); the task graph will serialise across them"
                )

            source_tasks, source_index = _sources_for_pool(
                pool, targets, provisioner, source_cache, drop_kinds, curated
            )
            tried = {source_index}
            while True:
                selected = _select_tests(source_tasks, test_filters, pool)
                selected = _repair_fetches(
                    selected,
                    pool,
                    source_cache[source_index]["labels"],
                    repair_indexes,
                )
                try:
                    source_tasks = _drop_blocked(selected, pool)
                    break
                except HwUpstreamError:
                    # Only this refusal is retryable, and only against an older
                    # push: a filter that matches nothing or a curated set the
                    # graph does not have will match nothing there either.
                    fallback_index, fallback_tasks = _earlier_push_source(
                        pool,
                        source_cache[source_index].get("decision"),
                        provisioner,
                        source_cache,
                        drop_kinds,
                        curated,
                        max(walkback - (len(tried) - 1), 0),
                        tried,
                    )
                    if not fallback_index:
                        raise
                    tried.add(fallback_index)
                    source_index, source_tasks = fallback_index, fallback_tasks
            _log_runtime_budget(pool, source_tasks, repeat)

            for source in source_tasks:
                for run_index in range(1, repeat + 1):
                    yield _build_task(
                        source,
                        task_name=task["name"],
                        pool=pool,
                        scheduler_id=scheduler_id,
                        source_index=source_index,
                        run_index=run_index,
                        run_count=repeat,
                    )


def _build_task(
    source, task_name, pool, scheduler_id, source_index, run_index=1, run_count=1
):
    task_def = deepcopy(source)
    task = task_def["task"]

    old_pool = f"{task['provisionerId']}/{task['workerType']}"
    new_pool = pool.task_queue_id

    task["workerType"] = pool.name
    task["schedulerId"] = scheduler_id
    task["taskGroupId"] = os.environ["TASK_ID"]
    task["priority"] = "low"
    task["routes"] = list(KEPT_ROUTES)
    task.get("extra", {}).pop("treeherder", None)

    _rewrite_caches(task, scheduler_id)
    _rewrite_scopes(task, old_pool, new_pool, scheduler_id)
    _rewrite_datestamps(task)

    # `*_REV` is kept, unlike the cloud path: the resolved dependency task ids
    # point at builds of exactly this revision.

    original_name = task["metadata"]["name"]
    label = f"{task_name}-{pool.name}-{original_name}"
    # Repeats have to differ somewhere: taskgraph derives a task id from the
    # label, so identical labels would collide into one task.
    if run_count > 1:
        label = f"{label}-run{run_index}"
    task["metadata"]["name"] = label

    return {
        "label": label,
        # Dependencies are already concrete task ids; nothing to resolve by label.
        "dependencies": {},
        "description": task["metadata"].get("description", ""),
        "task": task,
        "attributes": {
            "hw_replicate": task_name,
            "hw_pool": pool.name,
            "hw_source_label": source.get("label", original_name),
            "hw_source_worker_type": pool.source_worker_type,
            "hw_source_index": source_index,
            "hw_run_index": run_index,
            "hw_run_count": run_count,
            "hw_pool_image": pool.image,
            "hw_pool_branch": pool.src_branch,
            "hw_pool_revision": pool.revision,
        },
    }
