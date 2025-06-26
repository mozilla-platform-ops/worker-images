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

    @cache
    def _get_image_resources(self):
        resource_map = defaultdict(set)
        config_dir = Path("config")
        for path in config_dir.glob("*.yaml"):
            config = load_yaml(path)
            image_key = "sharedimage" if "sharedimage" in config else "image"
            image_name = config.get(image_key, {}).get("image_name")
            if not image_name:
                # Unknown config format
                continue

            resources = resource_map[image_name]
            resources.add(path)

            if scripts := config.get("vm", {}).get("script_paths"):
                resources.update(scripts)

        return resource_map

    @cache
    def _modified_images(self, files_changed: frozenset[str]) -> set[str]:
        resource_map = self._get_image_resources()

        images = set()
        for image, resources in resource_map.items():
            for resource in resources:
                if any(is_subpath(resource, Path(path)) for path in files_changed):
                    images.add(image)
                    break

        return images

    def should_remove_task(self, task, params, _) -> bool:
        task_queue_id = f"{task.task['provisionerId']}/{task.task['workerType']}"
        pool_images = get_worker_pool_images().get(task_queue_id, set())

        files_changed = frozenset(params["files_changed"])
        modified_images = self._modified_images(files_changed)

        if pool_images & modified_images:
            return False

        return True
