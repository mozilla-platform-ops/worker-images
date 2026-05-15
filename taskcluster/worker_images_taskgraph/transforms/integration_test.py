import logging
from functools import cache

from taskgraph.transforms.base import TransformSequence
from taskgraph.util.taskcluster import find_task_id, get_artifact

from worker_images_taskgraph.util.fxci import get_worker_pool_images

logger = logging.getLogger(__name__)
transforms = TransformSequence()

GECKO_OS_INTEGRATION_INDEX = (
    "gecko.v2.mozilla-central.latest.taskgraph.decision-os-integration"
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
