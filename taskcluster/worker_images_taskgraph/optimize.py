# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

from taskgraph.optimize.base import OptimizationStrategy, register_strategy

from worker_images_taskgraph.util.fxci import get_worker_pool_images


@register_strategy("integration-test")
class IntegrationTestStrategy(OptimizationStrategy):

    def should_remove_task(self, task, params, _) -> bool:
        # Translations tasks stay on their prod pool (no `-alpha` retargeting),
        # so the candidate image filter doesn't apply to them. Always keep them.
        if task.attributes.get("replicate") == "translations":
            return False

        task_queue_id = f"{task.task['provisionerId']}/{task.task['workerType']}"
        pool_images = get_worker_pool_images().get(task_queue_id, set())

        images = set(params["images"] or [])
        if pool_images & images:
            return False

        return True
