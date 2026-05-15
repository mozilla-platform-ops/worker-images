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
    setattr(util_taskcluster_module, "get_ancestors", lambda _: {})
    setattr(util_taskcluster_module, "get_task_definition", lambda _: {})

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
        translations_task = {
            "attributes": {"replicate": "translations"},
            "task": {"payload": {"env": {}}},
        }

        result = list(
            self.mod.restore_gecko_revision_env(
                None, [gecko_task, translations_task]
            )
        )

        self.assertEqual(
            result[0]["task"]["payload"]["env"]["GECKO_HEAD_REV"], "deadbeefcafe"
        )
        self.assertEqual(result[0]["task"]["payload"]["env"]["FOO"], "bar")
        # translations tasks are left alone
        self.assertNotIn("GECKO_HEAD_REV", result[1]["task"]["payload"]["env"])

    def test_change_worker_pool_to_alpha_skips_translations_tasks(self):
        # Translations build pools don't have `-alpha` variants. Make sure
        # the transform leaves translations tasks alone instead of dropping
        # them via the "no -alpha pool" code path.
        self.mod.get_worker_pool_images = lambda: {}

        class DummyConfig:
            kind = "integration-test"
            params = {"images": ["whatever"]}

        trans = {
            "attributes": {"replicate": "translations"},
            "task": {
                "provisionerId": "translations-1",
                "workerType": "b-linux-large-gcp-d2g",
                "scopes": [],
            },
        }

        result = list(self.mod.change_worker_pool_to_alpha(DummyConfig(), [trans]))

        self.assertEqual(len(result), 1)
        # Worker-type / scopes unchanged
        self.assertEqual(
            result[0]["task"]["workerType"], "b-linux-large-gcp-d2g"
        )

    def test_expand_translations_ancestors_replaces_placeholder(self):
        # Pretend replicate emitted a single placeholder translations task and
        # one unrelated gecko task. Stub the ancestor expansion to return two
        # synthetic build taskdescs.
        gecko_task = {
            "label": "gecko-test-foo",
            "attributes": {"replicate": "gecko"},
            "task": {},
        }
        translations_placeholder = {
            "label": "translations-all-pipeline-ru-en-1",
            "attributes": {"replicate": "translations"},
            "task": {"workerType": "succeed"},
        }
        synthesized = [
            {"label": "translations-build-ru-en", "attributes": {"replicate": "translations"}, "task": {}},
            {"label": "translations-train-ru-en", "attributes": {"replicate": "translations"}, "task": {}},
        ]
        self.mod._fetch_translations_ancestor_taskdescs = lambda: synthesized

        result = list(
            self.mod.expand_translations_ancestors(
                None, [gecko_task, translations_placeholder]
            )
        )

        labels = [t["label"] for t in result]
        # Placeholder is dropped; gecko untouched; synthesized translations added
        self.assertIn("gecko-test-foo", labels)
        self.assertNotIn("translations-all-pipeline-ru-en-1", labels)
        self.assertIn("translations-build-ru-en", labels)
        self.assertIn("translations-train-ru-en", labels)

    def test_expand_translations_ancestors_skips_when_no_translations(self):
        # No translations task in input => no upstream lookup, output equals input.
        self.mod._fetch_translations_ancestor_taskdescs = lambda: [
            {"label": "translations-should-not-appear", "attributes": {"replicate": "translations"}, "task": {}},
        ]
        gecko_only = [
            {"label": "gecko-test-foo", "attributes": {"replicate": "gecko"}, "task": {}},
        ]

        result = list(self.mod.expand_translations_ancestors(None, gecko_only))

        self.assertEqual([t["label"] for t in result], ["gecko-test-foo"])

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
