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

    class DummyTransformSequence:
        def add(self, fn):
            return fn

    setattr(base_module, "TransformSequence", DummyTransformSequence)

    sys.modules["taskgraph"] = taskgraph_module
    sys.modules["taskgraph.transforms"] = transforms_module
    sys.modules["taskgraph.transforms.base"] = base_module

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
            self.mod.get_worker_pool_variant("win11-a64-24h2-tester"),
            "win11-a64-tester",
        )
        self.assertEqual(
            self.mod.get_worker_pool_variant("win11-a64-25h2-builder"),
            "win11-a64-builder",
        )

    def test_prefers_arm64_pool_matching_requested_image(self):
        pool_images_by_pool = {
            "relops-1/win11-a64-24h2-tester-alpha": {"win11_a64_24h2_tester_alpha"},
            "relops-1/win11-a64-25h2-tester-alpha": {"win11a6425h2testeralpha"},
        }
        requested_images = {"win11a6425h2testeralpha"}

        selected = self.mod.get_image_compatible_alpha_worker_type(
            provisioner_id="relops-1",
            worker_type="win11-a64-24h2-tester",
            pool_images_by_pool=pool_images_by_pool,
            requested_images=requested_images,
        )

        self.assertEqual(selected, "win11-a64-25h2-tester-alpha")


if __name__ == "__main__":
    unittest.main()
