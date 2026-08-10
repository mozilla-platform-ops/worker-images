# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

"""Replicate mozilla-central's Windows hardware test tasks onto MDC1 HW pools.

Not built on mozilla_taskgraph's replicate transform: that discards every
releng-hardware task before consulting config, and bumping it would affect the
cloud integration-test kind. Namespaced away from the cloud path throughout.
"""

import logging
import os
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


def _fetch_source_tasks(index: str, provisioner: str, prefixes: tuple[str, ...]):
    """Return hardware task definitions from a decision task's scheduled graph."""
    decision_task_id = find_task_id(index)
    task_graph = get_artifact(decision_task_id, "public/task-graph.json")

    matched = []
    for label, task_def in sorted(task_graph.items()):
        task = task_def.get("task", {})
        if task.get("provisionerId") != provisioner:
            continue
        worker_type = task.get("workerType", "")
        if not any(worker_type.startswith(p) for p in prefixes):
            continue
        task_def.setdefault("label", label)
        matched.append(task_def)

    logger.info(
        f"hw-integration: {len(matched)} hardware task(s) in {index} "
        f"(decision {decision_task_id})"
    )
    if not matched:
        logger.warning(
            f"hw-integration: no {provisioner} tasks matching {prefixes} were "
            f"scheduled by {index}; nothing to replicate"
        )
    return matched


def _rewrite_scopes(task, old_pool: str, new_pool: str, cache_from: str, cache_to: str):
    """Keep holdable scopes, retarget pool-bound, drop the rest: an unholdable
    scope fails task creation, a dropped one only affects its own task."""
    kept, dropped = [], []
    for scope in task.get("scopes", []):
        if scope.startswith(_CACHE_SCOPE_PREFIX):
            kept.append(scope.replace(cache_from, cache_to))
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


def _rewrite_caches(task, cache_from: str, cache_to: str):
    payload = task.get("payload", {})

    if cache := payload.get("cache"):
        payload["cache"] = {k.replace(cache_from, cache_to): v for k, v in cache.items()}

    for mount in payload.get("mounts", []):
        if "cacheName" in mount:
            mount["cacheName"] = mount["cacheName"].replace(cache_from, cache_to)


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
        prefixes = tuple(replicate_config["worker-type-prefixes"])
        source_tasks = _fetch_source_tasks(
            replicate_config["target"], provisioner, prefixes
        )

        trust_domain = config.graph_config["trust-domain"]
        level = config.params["level"]
        scheduler_id = f"{trust_domain}-level-{level}"
        cache_to = f"{trust_domain}-level-{level}-"

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

            for source in source_tasks:
                yield _build_task(
                    source,
                    task_name=task["name"],
                    pool=pool,
                    scheduler_id=scheduler_id,
                    cache_to=cache_to,
                )


def _build_task(source, task_name, pool, scheduler_id, cache_to):
    task_def = deepcopy(source)
    task = task_def["task"]

    old_pool = f"{task['provisionerId']}/{task['workerType']}"
    new_pool = pool.task_queue_id
    # Derived from the source scheduler so `-pip`/`-uv` suffixes survive.
    cache_from = f"{source['task'].get('schedulerId', 'gecko-level-3')}-"

    task["workerType"] = pool.name
    task["schedulerId"] = scheduler_id
    task["taskGroupId"] = os.environ["TASK_ID"]
    task["priority"] = "low"
    task["routes"] = list(KEPT_ROUTES)
    task.get("extra", {}).pop("treeherder", None)

    _rewrite_caches(task, cache_from, cache_to)
    _rewrite_scopes(task, old_pool, new_pool, cache_from, cache_to)
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
            "hw_pool_image": pool.image,
            "hw_pool_branch": pool.src_branch,
            "hw_pool_revision": pool.revision,
        },
    }
