# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

import json
import os

from taskgraph.parameters import extend_parameters_schema
from voluptuous import Any, Required


def get_defaults(repo_root):
    return {
        "images": None,
    }


extend_parameters_schema(
    {
        Required("images"): Any(None, list[str]),
    },
    defaults_fn=get_defaults,
)


def get_decision_parameters(graph_config, parameters):
    if images := os.environ.get("DEPLOY_IMAGES"):
        parameters["images"] = json.loads(images)
