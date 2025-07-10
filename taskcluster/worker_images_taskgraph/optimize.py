# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

import glob
from functools import cache
from pathlib import Path

from taskgraph.optimize.base import OptimizationStrategy, register_strategy
from taskgraph.util.yaml import load_yaml

from worker_images_taskgraph.util.fxci import get_worker_pool_images


@register_strategy("integration-test")
class IntegrationTestStrategy(OptimizationStrategy):

    @cache
    def _modified_images(self, files_changed: frozenset[str]) -> set[str]:
        images = set()

        config_dir = Path("config")
        modified_config_files = set(map(str, config_dir.glob("*.yaml"))) & files_changed
        for path in modified_config_files:
            data = load_yaml(path)

            if image_name:= data.get("image", {}).get("image_name"):
                images.add(image_name)

            elif image_name:= data.get("sharedimage", {}).get("image_name"):
                images.add(image_name)

        return images

    def should_remove_task(self, task, params, _) -> bool:
        task_queue_id = f"{task.task['provisionerId']}/{task.task['workerType']}"
        pool_images = get_worker_pool_images().get(task_queue_id, set())

        files_changed = frozenset(params["files_changed"])
        modified_images = self._modified_images(files_changed)

        if pool_images & modified_images:
            return False

        return True
