import importlib
import sys
import types
import unittest


def _load_module():
    mozilla_taskgraph_module = types.ModuleType("mozilla_taskgraph")
    setattr(mozilla_taskgraph_module, "register", lambda graph_config: None)
    sys.modules["mozilla_taskgraph"] = mozilla_taskgraph_module

    taskgraph_module = types.ModuleType("taskgraph")
    transforms_module = types.ModuleType("taskgraph.transforms")
    base_module = types.ModuleType("taskgraph.transforms.base")
    util_module = types.ModuleType("taskgraph.util")
    util_taskcluster_module = types.ModuleType("taskgraph.util.taskcluster")

    class DummyTransformSequence:
        def add(self, fn):
            return fn

    setattr(base_module, "TransformSequence", DummyTransformSequence)
    setattr(util_taskcluster_module, "find_task_id", lambda _: "stub-task-id")
    setattr(util_taskcluster_module, "get_artifact", lambda *_: {})

    sys.modules["taskgraph"] = taskgraph_module
    sys.modules["taskgraph.transforms"] = transforms_module
    sys.modules["taskgraph.transforms.base"] = base_module
    sys.modules["taskgraph.util"] = util_module
    sys.modules["taskgraph.util.taskcluster"] = util_taskcluster_module

    fxci_module = types.ModuleType("worker_images_taskgraph.util.fxci")
    setattr(fxci_module, "get_worker_pool_images", lambda: {})
    sys.modules["worker_images_taskgraph.util.fxci"] = fxci_module

    return importlib.import_module(
        "worker_images_taskgraph.transforms.integration_test"
    )


class TestIntegrationTestTransform(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = _load_module()

    def test_get_worker_pool_variant_arm64(self):
        self.assertEqual(
            self.mod.get_worker_pool_variant("win11-a64-25h2-tester"),
            "win11-a64-tester",
        )
        self.assertEqual(
            self.mod.get_worker_pool_variant("win11-a64-25h2-builder"),
            "win11-a64-builder",
        )

    def test_change_worker_pool_to_alpha_rewrites_pool_bound_scopes(self):
        # `change_worker_pool_to_alpha` imported get_worker_pool_images via
        # `from ... import`, so patch the binding in the transform module itself.
        self.mod.get_worker_pool_images = lambda: {
            "gecko-t/t-linux-2404-wayland-snap-alpha": {
                "gw-fxci-gcp-l1-2404-amd64-gui-googlecompute-alpha"
            },
        }

        class DummyConfig:
            kind = "integration-test"
            params = {"images": ["gw-fxci-gcp-l1-2404-amd64-gui-googlecompute-alpha"]}

        task = {
            "task": {
                "provisionerId": "gecko-t",
                "workerType": "t-linux-2404-wayland-snap",
                "scopes": [
                    "generic-worker:os-group:gecko-t/t-linux-2404-wayland-snap/snap_sudo",
                    "queue:scheduler-id:relops-level-1",
                ],
            }
        }

        result = list(self.mod.change_worker_pool_to_alpha(DummyConfig(), [task]))

        self.assertEqual(len(result), 1)
        out = result[0]["task"]
        self.assertEqual(out["workerType"], "t-linux-2404-wayland-snap-alpha")
        self.assertEqual(
            out["scopes"],
            [
                "generic-worker:os-group:gecko-t/t-linux-2404-wayland-snap-alpha/snap_sudo",
                "queue:scheduler-id:relops-level-1",
            ],
        )

    def test_restore_gecko_revision_env_injects_revs_for_gecko_tasks(self):
        self.mod._fetch_gecko_revision_env = lambda: {
            "GECKO_HEAD_REV": "deadbeefcafe",
            "GECKO_HEAD_REPOSITORY": "https://hg.mozilla.org/mozilla-central",
        }

        gecko_task = {
            "attributes": {"replicate": "gecko"},
            "task": {"payload": {"env": {"FOO": "bar"}}},
        }
        non_gecko_task = {
            "attributes": {"replicate": "other"},
            "task": {"payload": {"env": {}}},
        }

        result = list(
            self.mod.restore_gecko_revision_env(
                None, [gecko_task, non_gecko_task]
            )
        )

        self.assertEqual(
            result[0]["task"]["payload"]["env"]["GECKO_HEAD_REV"], "deadbeefcafe"
        )
        self.assertEqual(result[0]["task"]["payload"]["env"]["FOO"], "bar")
        # non-gecko tasks are left alone
        self.assertNotIn("GECKO_HEAD_REV", result[1]["task"]["payload"]["env"])

    def test_restore_gecko_revision_env_does_not_overwrite_existing(self):
        self.mod._fetch_gecko_revision_env = lambda: {
            "GECKO_HEAD_REV": "newrev",
        }

        task = {
            "attributes": {"replicate": "gecko"},
            "task": {"payload": {"env": {"GECKO_HEAD_REV": "existingrev"}}},
        }

        result = list(self.mod.restore_gecko_revision_env(None, [task]))

        self.assertEqual(
            result[0]["task"]["payload"]["env"]["GECKO_HEAD_REV"], "existingrev"
        )


if __name__ == "__main__":
    unittest.main()
