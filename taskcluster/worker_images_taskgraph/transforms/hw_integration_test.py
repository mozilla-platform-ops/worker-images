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

import logging
import os
import re
from collections import defaultdict
from copy import deepcopy
from pathlib import Path

from taskgraph.transforms.base import TransformSequence
from taskgraph.util.taskcluster import find_task_id, get_artifact

from worker_images_taskgraph.util.hw_pools import (
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


def _repo_root(config) -> Path:
    root_dir = getattr(config.graph_config, "root_dir", None)
    if root_dir:
        candidate = Path(root_dir).parent
        if (candidate / "provisioners").is_dir():
            return candidate
    from worker_images_taskgraph.util.hw_pools import find_repo_root

    return find_repo_root()


def _fetch_source_tasks(index: str, provisioner: str) -> dict[str, list]:
    """Hardware task definitions from a decision task's graph, by worker type."""
    decision_task_id = find_task_id(index)
    task_graph = get_artifact(decision_task_id, "public/task-graph.json")

    by_worker_type = defaultdict(list)
    for label, task_def in sorted(task_graph.items()):
        task = task_def.get("task", {})
        if task.get("provisionerId") != provisioner:
            continue
        task_def.setdefault("label", label)
        by_worker_type[task["workerType"]].append(task_def)

    logger.info(
        f"hw-integration: {index} (decision {decision_task_id}) has "
        f"{sum(len(v) for v in by_worker_type.values())} {provisioner} task(s) "
        f"across {len(by_worker_type)} worker type(s)"
    )
    return dict(by_worker_type)


def _sources_for_pool(pool, targets: list[str], provisioner: str, cache: dict):
    """Tasks for the pool's counterpart, from the first target index that has any.

    Ordered rather than merged: the os-integration index carries a curated set
    sized for a small pool, and the push decision -- the only index that
    schedules `-hw-ref` tasks -- carries a full tier-1 run's worth. Fetching is
    lazy so selecting only `-hw` pools never downloads the larger graph.
    """
    seen_worker_types = set()

    for index in targets:
        if index not in cache:
            cache[index] = _fetch_source_tasks(index, provisioner)
        by_worker_type = cache[index]
        seen_worker_types.update(by_worker_type)

        if matched := by_worker_type.get(pool.source_worker_type):
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


def _log_runtime_budget(pool, source_tasks):
    """Worst-case hardware time, so the decision log says what a run will cost
    before the caller's timeout has to discover it."""
    budget = sum(
        source["task"].get("payload", {}).get("maxRunTime", 0)
        for source in source_tasks
    )
    if not budget:
        return
    hours = budget / 3600
    per_node = f", ~{hours / pool.node_count:.1f}h across {pool.node_count} node(s)"
    logger.info(
        f"hw-integration: {pool.name}: {len(source_tasks)} task(s), "
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
        source_cache: dict[str, dict[str, list]] = {}

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
                pool, targets, provisioner, source_cache
            )
            _log_runtime_budget(pool, source_tasks)

            for source in source_tasks:
                yield _build_task(
                    source,
                    task_name=task["name"],
                    pool=pool,
                    scheduler_id=scheduler_id,
                    source_index=source_index,
                )


def _build_task(source, task_name, pool, scheduler_id, source_index):
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
            "hw_pool_image": pool.image,
            "hw_pool_branch": pool.src_branch,
            "hw_pool_revision": pool.revision,
        },
    }
