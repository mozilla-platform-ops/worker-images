import logging

from taskgraph.transforms.base import TransformSequence

from worker_images_taskgraph.util.fxci import get_worker_pool_images

logger = logging.getLogger(__name__)
transforms = TransformSequence()


@transforms.add
def change_worker_pool_to_alpha(config, tasks):
    pools = get_worker_pool_images().keys()

    for task in tasks:
        new_worker_type = f"{task["task"]["workerType"]}-alpha"
        new_pool = f"{task['task']['provisionerId']}/{new_worker_type}"

        if new_pool not in pools:
            logger.debug(f"skipping {config.kind} task because {new_pool} does not exist")
            continue

        task["task"]["workerType"] = new_worker_type
        yield task


@transforms.add
def add_optimization(config, tasks):
    for task in tasks:
        task["optimization"] = {"integration-test": None}
        yield task
