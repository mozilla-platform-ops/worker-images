# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

"""Replicate autoland's tier 1 Windows hardware tasks onto MDC1 HW pools."""

import logging
from copy import deepcopy
from pathlib import Path

from mozilla_taskgraph.transforms.replicate import (
    rewrite_task as replicate_rewrite_task,
)
from taskgraph.transforms.base import TransformSequence
from taskgraph.util.taskcluster import find_task_id, get_artifact
from worker_images_taskgraph.util.hw_pools import (
    HwPoolError,
    load_registry,
)

logger = logging.getLogger(__name__)
transforms = TransformSequence()

# Replaced wholesale: the source tasks carry autoland's own index and
# treeherder routes, which a retargeted run must not write to.
KEPT_ROUTES: list[str] = []
REQUIRED_TIER = 1

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
        if task.get("extra", {}).get("treeherder", {}).get("tier") != REQUIRED_TIER:
            continue
        task_def.setdefault("label", label)
        matched.append(task_def)

    logger.info(
        f"hw-integration: {len(matched)} tier 1 hardware task(s) in {index} "
        f"(decision {decision_task_id})"
    )
    if not matched:
        logger.warning(
            f"hw-integration: no tier 1 {provisioner} tasks matching {prefixes} "
            f"were scheduled by {index}; nothing to replicate"
        )
    return matched


def _rewrite_scopes(task, old_pool: str, new_pool: str):
    """Keep holdable scopes, retarget pool-bound, drop the rest: an unholdable
    scope fails task creation, a dropped one only affects its own task."""
    kept, dropped = [], []
    for scope in task.get("scopes", []):
        if scope.startswith(_CACHE_SCOPE_PREFIX):
            kept.append(scope)
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
                    config,
                    source,
                    task_name=task["name"],
                    pool=pool,
                )


def _build_task(config, source, task_name, pool):
    source_task = deepcopy(source)
    task = source_task["task"]
    old_pool = f"{task['provisionerId']}/{task['workerType']}"
    revision_env = {
        key: value
        for key, value in task.get("payload", {}).get("env", {}).items()
        if key.endswith("_REV")
    }
    original_name = task["metadata"]["name"]

    source_task["name-prefix"] = f"{task_name}-{pool.name}"
    task_desc = next(replicate_rewrite_task(config, [source_task]))
    task = task_desc["task"]

    task["workerType"] = pool.name
    task["routes"] = list(KEPT_ROUTES)
    task.setdefault("payload", {}).setdefault("env", {}).update(revision_env)
    _rewrite_scopes(task, old_pool, pool.task_queue_id)

    task_desc["attributes"] = {
        "hw_replicate": task_name,
        "hw_pool": pool.name,
        "hw_source_label": source.get("label", original_name),
        "hw_source_tier": REQUIRED_TIER,
        "hw_pool_image": pool.image,
        "hw_pool_branch": pool.src_branch,
        "hw_pool_revision": pool.revision,
    }
    return task_desc
