# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

"""A decision task validates parameters strictly, so `get_decision_parameters`
has to set every key the schema extension adds -- the defaults in
`get_defaults` are only consulted for non-strict `Parameters`. Leaving one out
fails generation with "required key not provided", which is how the first
hardware cron run died.
"""

import importlib
import os
import sys
import types
import unittest


def _load_parameters_module():
    """Stub `taskgraph.parameters`, capturing what the module registers."""
    captured = {}

    # Importing the package runs its `register` import, which pulls in
    # mozilla_taskgraph; it is not needed to check parameter handling.
    if "mozilla_taskgraph" not in sys.modules:
        mozilla_taskgraph_module = types.ModuleType("mozilla_taskgraph")
        setattr(mozilla_taskgraph_module, "register", lambda graph_config: None)
        sys.modules["mozilla_taskgraph"] = mozilla_taskgraph_module

    def extend_parameters_schema(schema, defaults_fn=None):
        captured["schema"] = schema
        captured["defaults_fn"] = defaults_fn

    taskgraph_module = sys.modules.setdefault(
        "taskgraph", types.ModuleType("taskgraph")
    )
    parameters_module = types.ModuleType("taskgraph.parameters")
    setattr(parameters_module, "extend_parameters_schema", extend_parameters_schema)
    sys.modules["taskgraph.parameters"] = parameters_module
    setattr(taskgraph_module, "parameters", parameters_module)

    sys.modules.pop("worker_images_taskgraph.parameters", None)
    module = importlib.import_module("worker_images_taskgraph.parameters")
    return module, captured


class TestDecisionParameters(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod, cls.captured = _load_parameters_module()

    def setUp(self):
        for name in ("DEPLOY_IMAGES", "DEPLOY_HW_POOLS"):
            self.addCleanup(os.environ.pop, name, None)
            os.environ.pop(name, None)

    def _run(self):
        parameters = {"level": "3"}
        self.mod.get_decision_parameters(object(), parameters)
        return parameters

    def _extended_keys(self):
        return {str(key.schema) for key in self.captured["schema"]}

    def test_every_extended_key_is_set_even_with_no_cron_input(self):
        parameters = self._run()
        for key in self._extended_keys():
            self.assertIn(key, parameters, f"{key} would fail strict validation")
            self.assertIsNone(parameters[key])

    def test_defaults_cover_the_same_keys_as_the_schema(self):
        self.assertEqual(
            set(self.captured["defaults_fn"](None)),
            self._extended_keys(),
            "a key in one and not the other is the bug this file guards",
        )

    def test_image_input_does_not_leave_hw_pools_unset(self):
        os.environ["DEPLOY_IMAGES"] = '["win11-64-25h2-alpha"]'
        parameters = self._run()
        self.assertEqual(parameters["images"], ["win11-64-25h2-alpha"])
        self.assertIsNone(parameters["hw_pools"])

    def test_hw_pool_input_does_not_leave_images_unset(self):
        os.environ["DEPLOY_HW_POOLS"] = '["win11-64-24h2-hw-perf-debug"]'
        parameters = self._run()
        self.assertEqual(parameters["hw_pools"], ["win11-64-24h2-hw-perf-debug"])
        self.assertIsNone(parameters["images"])

    def test_empty_env_var_is_not_json_decoded(self):
        os.environ["DEPLOY_IMAGES"] = ""
        os.environ["DEPLOY_HW_POOLS"] = ""
        parameters = self._run()
        self.assertIsNone(parameters["images"])
        self.assertIsNone(parameters["hw_pools"])


if __name__ == "__main__":
    unittest.main()
