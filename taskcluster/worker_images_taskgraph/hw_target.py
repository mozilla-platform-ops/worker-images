# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

from taskgraph.target_tasks import register_target_task


@register_target_task("hw-integration")
def hw_integration(full_task_graph, parameters, graph_config):
    """Hardware tasks only: keyed on ``hw_replicate``, not target.py's
    ``replicate``, so the cloud and hardware runs stay disjoint."""
    return [
        label
        for label, task in full_task_graph.tasks.items()
        if "hw_replicate" in task.attributes
    ]
