# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

import logging

from taskgraph.actions.registry import register_callback_action
from taskgraph.decision import taskgraph_decision
from taskgraph.parameters import Parameters

logger = logging.getLogger(__name__)


@register_callback_action(
    name="run-integration-tests",
    title="Run Firefox-CI integration tests",
    symbol="run-integration",
    description="Run Firefox-CI integration tests",
    permission="run-integration-tests",
    context=[],
    schema={},
)
def run_integration_tests(parameters, graph_config, input, task_group_id, task_id):
    # make parameters read-write
    parameters = dict(parameters)

    parameters["target_tasks_method"] = "integration"
    parameters["tasks_for"] = "action"

    # make parameters read-only
    parameters = Parameters(**parameters)

    taskgraph_decision({"root": graph_config.root_dir}, parameters=parameters)
