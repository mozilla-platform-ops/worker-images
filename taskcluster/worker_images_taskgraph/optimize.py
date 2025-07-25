# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

from collections import defaultdict
from functools import cache
from pathlib import Path

from taskgraph.optimize.base import OptimizationStrategy, register_strategy
from taskgraph.util.yaml import load_yaml

from worker_images_taskgraph.util.fxci import get_worker_pool_images


def is_subpath(base: Path, target: Path) -> bool:
    try:
        target.relative_to(base)
        return True
    except ValueError:
        return False


@register_strategy("integration-test")
class IntegrationTestStrategy(OptimizationStrategy):

    def should_remove_task(self, task, params, _) -> bool:
        task_queue_id = f"{task.task['provisionerId']}/{task.task['workerType']}"
        pool_images = get_worker_pool_images().get(task_queue_id, set())

        images = params["images"] or set()
        if pool_images & images:
            return False

        return True
