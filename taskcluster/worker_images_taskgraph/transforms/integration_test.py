import logging
import re
from functools import cache

from taskgraph.transforms.base import TransformSequence
from taskgraph.util.taskcluster import (
    find_task_id,
    get_ancestors,
    get_artifact,
    get_task_definition,
)

from worker_images_taskgraph.util.fxci import get_worker_pool_images

logger = logging.getLogger(__name__)
transforms = TransformSequence()

GECKO_OS_INTEGRATION_INDEX = (
    "gecko.v2.mozilla-central.latest.taskgraph.decision-os-integration"
)
TRANSLATIONS_PIPELINE_INDEX = (
    "translations.v2.translations.latest.taskgraph.decision-run-pipeline"
)
# Walk ancestors of the translations all-pipeline task. Skip the decision /
# action / docker-image tasks (their definitions don't survive replication).
# Mirrors `include-deps` in `taskcluster/kinds/integration-test/kind.yml`.
TRANSLATIONS_INCLUDE_DEPS = re.compile(
    r"^(?!(Decision|Action|PR action|build-docker-image|docker-image)).*"
)


@cache
def _fetch_gecko_revision_env() -> dict[str, str]:
    """Return the gecko revision env vars from the mc os-integration decision.

    `mozilla_taskgraph.transforms.replicate` strips every `*_REV` env var from
    replicated tasks. `run-task-hg` then can't find the revision to check out
    and refuses with "task should be defined in terms of non-symbolic
    revision". Re-fetch them from the decision task's `task-graph.json` so
    replicated tasks check out the same gecko revision the decision ran on.
    """
    try:
        decision_task_id = find_task_id(GECKO_OS_INTEGRATION_INDEX)
        task_graph = get_artifact(decision_task_id, "public/task-graph.json")
    except Exception as e:
        logger.warning(f"could not fetch gecko os-integration decision: {e}")
        return {}

    for task in task_graph.values():
        env = task.get("task", {}).get("payload", {}).get("env", {})
        revs = {k: v for k, v in env.items() if k.endswith("_REV")}
        if revs:
            return revs

    return {}


def _rewrite_datestamps(task_def: dict) -> None:
    """Make timestamps relative so the replicated task can be re-scheduled."""
    task_def["created"] = {"relative-datestamp": "0 seconds"}
    task_def["deadline"] = {"relative-datestamp": "1 day"}
    task_def["expires"] = {"relative-datestamp": "1 month"}

    payload = task_def.get("payload", {})
    artifacts = payload.get("artifacts")
    if isinstance(artifacts, dict):
        for k in artifacts:
            if "expires" in artifacts[k]:
                artifacts[k]["expires"] = {"relative-datestamp": "1 month"}
    elif isinstance(artifacts, list):
        for a in artifacts:
            if "expires" in a:
                a["expires"] = {"relative-datestamp": "1 month"}


def _remove_revisions(task_def: dict) -> None:
    """Strip absolute `*_REV` env vars to avoid pointing at stale revisions."""
    env = task_def.get("payload", {}).get("env", {})
    for k in [k for k in env if k.endswith("_REV")]:
        del env[k]


def _replicate_ancestor_task(name_prefix: str, task_def: dict) -> dict:
    """Normalize an upstream task definition into a replicated task description.

    Matches the shape `mozilla_taskgraph.transforms.replicate` produces for the
    original target tasks: name-prefixed, datestamps rewritten, scopes/level
    dropped from 3 to 1, and no leftover dependencies.
    """
    _rewrite_datestamps(task_def)
    _remove_revisions(task_def)

    # taskQueueId never matches the staging cluster; let provisionerId/workerType
    # be the source of truth.
    task_def.pop("taskQueueId", None)
    for key in ("provisionerId", "workerType"):
        if key in task_def:
            task_def[key] = task_def[key].replace("3", "1")

    for i, scope in enumerate(task_def.get("scopes", [])):
        task_def["scopes"][i] = scope.replace("gecko-level-3", "releng-level-1")

    orig_name = task_def["metadata"]["name"]
    task_def["metadata"]["name"] = f"{name_prefix}-{orig_name}"

    return {
        "label": task_def["metadata"]["name"],
        "dependencies": {},
        "description": task_def["metadata"].get("description", ""),
        "task": task_def,
        "attributes": {"replicate": name_prefix},
    }


@cache
def _fetch_translations_ancestor_taskdescs() -> list[dict]:
    """Return replicated taskdescs for ancestors of the translations pipeline.

    `mozilla_taskgraph.transforms.replicate` doesn't honor `include-deps`, so
    only the synthetic `all-pipeline` task (a `succeed` pseudo-worker) survives
    the default flow. Walk that task's ancestors via Taskcluster's queue API
    to pull in the real translations build/run tasks, mirroring the logic in
    `fxci_config_taskgraph.util.integration.find_tasks`.
    """
    try:
        decision_task_id = find_task_id(TRANSLATIONS_PIPELINE_INDEX)
        task_graph = get_artifact(decision_task_id, "public/task-graph.json")
    except Exception as e:
        logger.warning(f"could not fetch translations decision: {e}")
        return []

    ancestor_ids: set[str] = set()
    for tid, t in task_graph.items():
        if t.get("attributes", {}).get("stage") != "all-pipeline":
            continue
        try:
            ancestors = get_ancestors(tid)
        except Exception as e:
            logger.warning(f"get_ancestors failed for {tid}: {e}")
            continue
        for aid, label in ancestors.items():
            if TRANSLATIONS_INCLUDE_DEPS.match(label):
                ancestor_ids.add(aid)

    taskdescs: list[dict] = []
    for aid in ancestor_ids:
        try:
            task_def = get_task_definition(aid)
        except Exception as e:
            logger.warning(f"get_task_definition failed for {aid}: {e}")
            continue
        taskdescs.append(_replicate_ancestor_task("translations", task_def))

    return taskdescs


def normalize_image_name(image_name: str) -> str:
    return "".join(c for c in image_name.lower() if c.isalnum())


def get_normalized_images(images: list[str] | set[str]) -> set[str]:
    return {normalize_image_name(image) for image in images if image}


def pool_matches_images(pool_images: set[str], requested_images: set[str]) -> bool:
    if not requested_images:
        return True
    return bool(get_normalized_images(pool_images) & requested_images)


def get_worker_pool_variant(worker_type: str) -> str | None:
    parts = worker_type.split("-")

    if len(parts) == 3 and parts[0] == "win11" and parts[1] == "64":
        return "win11-64-base"

    if len(parts) == 4 and parts[0] == "win11" and parts[1] == "64":
        if parts[3] in {"gpu", "source"}:
            return f"win11-64-{parts[3]}"

    if len(parts) == 4 and parts[0] == "win11" and parts[1] == "a64":
        if parts[3] in {"tester", "builder"}:
            return f"win11-a64-{parts[3]}"

    return None


def get_image_compatible_alpha_worker_type(
    provisioner_id: str,
    worker_type: str,
    pool_images_by_pool: dict[str, set[str]],
    requested_images: set[str],
) -> str | None:
    default_worker_type = f"{worker_type}-alpha"
    default_pool = f"{provisioner_id}/{default_worker_type}"

    if default_pool in pool_images_by_pool:
        if pool_matches_images(pool_images_by_pool[default_pool], requested_images):
            return default_worker_type

    if not requested_images:
        return default_worker_type if default_pool in pool_images_by_pool else None

    variant = get_worker_pool_variant(worker_type)
    if variant is None:
        return default_worker_type if default_pool in pool_images_by_pool else None

    for pool_id, pool_images in sorted(pool_images_by_pool.items()):
        pool_provisioner, candidate_worker_type = pool_id.split("/", 1)
        if pool_provisioner != provisioner_id:
            continue
        if not candidate_worker_type.endswith("-alpha"):
            continue

        candidate_base = candidate_worker_type[: -len("-alpha")]
        if get_worker_pool_variant(candidate_base) != variant:
            continue

        if pool_matches_images(pool_images, requested_images):
            return candidate_worker_type

    return default_worker_type if default_pool in pool_images_by_pool else None


@transforms.add
def expand_translations_ancestors(config, tasks):
    """Replace replicate's translations output with ancestor-walked tasks.

    `mozilla_taskgraph.transforms.replicate` silently ignores `include-deps`, so
    the translations entry in `kind.yml` only ever produces a single
    `succeed`-typed placeholder (no `-alpha` pool exists for the built-in
    `succeed` worker, so even that gets dropped downstream and translations
    effectively never validates anything). Drop replicate's translations
    placeholder and emit replicated taskdescs for the real ancestor tasks
    (build/pipeline steps) instead.
    """
    has_translations = False
    for task in tasks:
        if task.get("attributes", {}).get("replicate") == "translations":
            has_translations = True
            continue
        yield task

    if not has_translations:
        return

    for taskdesc in _fetch_translations_ancestor_taskdescs():
        yield taskdesc


@transforms.add
def change_worker_pool_to_alpha(config, tasks):
    pool_images_by_pool = get_worker_pool_images()
    requested_images = get_normalized_images(list(config.params.get("images") or []))

    for task in tasks:
        provisioner_id = task["task"]["provisionerId"]
        worker_type = task["task"]["workerType"]
        old_pool = f"{provisioner_id}/{worker_type}"
        new_worker_type = get_image_compatible_alpha_worker_type(
            provisioner_id,
            worker_type,
            pool_images_by_pool,
            requested_images,
        )

        if new_worker_type is None:
            logger.debug(
                f"skipping {config.kind} task because {old_pool} does not have a corresponding `-alpha` pool configured!"
            )
            continue

        new_pool = f"{provisioner_id}/{new_worker_type}"
        task["task"]["workerType"] = new_worker_type
        # Pool-bound scopes (eg. generic-worker:os-group:<pool>/<group>)
        # reference the original prod pool id. Rewrite them to the alpha
        # pool so the alpha worker honors them and the decision task can
        # create the task with scopes it actually holds.
        if old_pool != new_pool and "scopes" in task["task"]:
            task["task"]["scopes"] = [
                scope.replace(old_pool, new_pool) for scope in task["task"]["scopes"]
            ]
        yield task


@transforms.add
def restore_gecko_revision_env(config, tasks):
    """Re-inject `*_REV` env vars stripped by mozilla_taskgraph's replicate."""
    revs = None
    for task in tasks:
        if task.get("attributes", {}).get("replicate") != "gecko":
            yield task
            continue

        if revs is None:
            revs = _fetch_gecko_revision_env()

        env = task["task"].setdefault("payload", {}).setdefault("env", {})
        for k, v in revs.items():
            env.setdefault(k, v)
        yield task


@transforms.add
def add_optimization(config, tasks):
    for task in tasks:
        task["optimization"] = {"integration-test": None}
        yield task
