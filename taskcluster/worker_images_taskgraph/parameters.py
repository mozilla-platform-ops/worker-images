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
        "hw_pools": None,
    }


extend_parameters_schema(
    {
        Required("images"): Any(None, list[str]),
        # Hardware pool names from pools.yml; selected by name rather than
        # inferred from an image, since they have no worker-manager entry.
        Required("hw_pools"): Any(None, list[str]),
    },
    defaults_fn=get_defaults,
)


def _json_from_env(name):
    """Cron input reaches us JSON-encoded by .taskcluster.yml, or not at all."""
    raw = os.environ.get(name)
    return json.loads(raw) if raw else None


def get_decision_parameters(graph_config, parameters):
    # Set both keys unconditionally. A decision task builds `Parameters` in
    # strict mode, where `get_defaults` above is never consulted, so a key this
    # function leaves unset fails generation with "required key not provided"
    # rather than defaulting to None -- which is how the hardware cron, whose
    # input carries `pools` and no `images`, failed.
    parameters["images"] = _json_from_env("DEPLOY_IMAGES")
    parameters["hw_pools"] = _json_from_env("DEPLOY_HW_POOLS")
