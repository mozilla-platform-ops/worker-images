import logging

from taskgraph.transforms.base import TransformSequence
from voluptuous import ALLOW_EXTRA, Optional, Schema

from worker_images_taskgraph.util.fxci import get_worker_pool_images

logger = logging.getLogger(__name__)
transforms = TransformSequence()


INTEGRATION_TEST_SCHEMA = Schema(
    {
        # Explicit worker pool mappings: old-pool -> new-pool
        # Use this for cross-provisioner mappings like:
        #   gecko-3/b-win2022 -> gecko-1/b-win2022-alpha
        Optional("worker-pool-mappings"): {str: str},
    },
    extra=ALLOW_EXTRA,
)


transforms.add_validate(INTEGRATION_TEST_SCHEMA)


def _get_pool_mappings_for_task(config, task_label):
    """
    Get pool mappings for a task based on its label prefix.

    Task labels from replicate transform are prefixed with the original task name,
    e.g., "gecko-builds-build-win64/opt" came from "gecko-builds" task definition.
    """
    tasks_config = config.config.get("tasks", {})

    # Sort by task name length (longest first) to match most specific prefix
    # This ensures "gecko-builds" matches before "gecko" for labels like
    # "gecko-builds-build-win64/opt"
    for task_name, task_def in sorted(
        tasks_config.items(), key=lambda x: len(x[0]), reverse=True
    ):
        # Check if the label starts with this task name
        prefix = f"{task_name}-"
        if task_label.startswith(prefix):
            mappings = task_def.get("worker-pool-mappings", {})
            logger.info(f"Label '{task_label}' matches '{task_name}', mappings: {mappings}")
            return mappings

    logger.info(f"No task definition match for label: {task_label}")
    return {}


@transforms.add
def change_worker_pool_to_alpha(config, tasks):
    pools = get_worker_pool_images().keys()

    # Log available task definitions once
    tasks_config = config.config.get("tasks", {})
    logger.info(f"Available task definitions: {list(tasks_config.keys())}")
    for tn, td in tasks_config.items():
        if "worker-pool-mappings" in td:
            logger.info(f"Task {tn} has worker-pool-mappings: {td['worker-pool-mappings']}")

    for task in tasks:
        task_label = task.get("label", "")
        logger.debug(f"Processing task with label: {task_label}")

        # Get pool mappings based on which original task definition this came from
        pool_mappings = _get_pool_mappings_for_task(config, task_label)

        old_provisioner = task["task"]["provisionerId"]
        old_worker_type = task["task"]["workerType"]
        old_pool = f"{old_provisioner}/{old_worker_type}"

        # If explicit pool mappings are defined for this task definition,
        # only remap pools that match a mapping; pass others through unchanged.
        if pool_mappings:
            if old_pool in pool_mappings:
                new_pool = pool_mappings[old_pool]
                if new_pool not in pools:
                    logger.debug(
                        f"skipping {config.kind} task because mapped pool {new_pool} "
                        f"is not configured!"
                    )
                    continue
                new_provisioner, new_worker_type = new_pool.split("/", 1)
                task["task"]["provisionerId"] = new_provisioner
                task["task"]["workerType"] = new_worker_type
                logger.debug(f"Mapped {old_pool} -> {new_pool}")
            else:
                logger.debug(
                    f"No pool mapping for {old_pool}, passing through unchanged"
                )
            yield task
            continue

        # Default behavior: add -alpha suffix to worker type
        new_worker_type = f"{old_worker_type}-alpha"
        new_pool = f"{old_provisioner}/{new_worker_type}"

        if new_pool not in pools:
            logger.debug(
                f"skipping {config.kind} task because {old_pool} does not have "
                f"a corresponding `-alpha` pool configured!"
            )
            continue

        task["task"]["workerType"] = new_worker_type
        yield task


@transforms.add
def add_optimization(config, tasks):
    for task in tasks:
        task["optimization"] = {"integration-test": None}
        yield task
