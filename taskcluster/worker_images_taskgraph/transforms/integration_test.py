import logging

from taskgraph.transforms.base import TransformSequence

from worker_images_taskgraph.util.fxci import get_worker_pool_images

logger = logging.getLogger(__name__)
transforms = TransformSequence()

def normalize_image_name(image_name: str) -> str:
    return "".join(c for c in image_name.lower() if c.isalnum())


def get_normalized_images(images: list[str] | set[str]) -> set[str]:
    return {normalize_image_name(image) for image in images if image}


def pool_matches_images(pool_images: set[str], requested_images: set[str]) -> bool:
    if not requested_images:
        return True
    return bool(get_normalized_images(pool_images) & requested_images)


def get_win11_64_variant(worker_type: str) -> str | None:
    parts = worker_type.split("-")

    if len(parts) == 3 and parts[0] == "win11" and parts[1] == "64":
        return "base"

    if len(parts) == 4 and parts[0] == "win11" and parts[1] == "64":
        if parts[3] in {"gpu", "source"}:
            return parts[3]

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

    variant = get_win11_64_variant(worker_type)
    if variant is None:
        return default_worker_type if default_pool in pool_images_by_pool else None

    for pool_id, pool_images in sorted(pool_images_by_pool.items()):
        pool_provisioner, candidate_worker_type = pool_id.split("/", 1)
        if pool_provisioner != provisioner_id:
            continue
        if not candidate_worker_type.endswith("-alpha"):
            continue

        candidate_base = candidate_worker_type[: -len("-alpha")]
        if get_win11_64_variant(candidate_base) != variant:
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

        task["task"]["workerType"] = new_worker_type
        yield task


@transforms.add
def add_optimization(config, tasks):
    for task in tasks:
        task["optimization"] = {"integration-test": None}
        yield task
