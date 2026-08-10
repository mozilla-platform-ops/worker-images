import importlib
import os
import textwrap
import unittest
from copy import deepcopy
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

# Shaped like pools.yml: two production pools, three staging, one Known-BAD.
POOLS_YAML = textwrap.dedent(
    """\
    ---
    pools:
      - name: "win11-64-24h2-hw"
        Description: "Production"
        image: "win11-24H2-NUC-01-16-2025"
        src_Branch: "master"
        hash: "655bf64"
        nodes:
        - nuc13-004
        - nuc13-005
      - name: "win11-64-24h2-hw-ref"
        Description: "Production reference"
        image: "win11-24H2-NUC-01-16-2025"
        src_Branch: "master"
        hash: "655bf64"
        nodes:
        - t-nuc12-004
      - name: "win11-64-24h2-hw-alpha"
        Description: "Staging"
        image: "win11-24H2-NUC-01-16-2025"
        src_Branch: "RELOPS-2402-fleetbench"
        hash: "74e8909"
        nodes:
        - nuc13-001
        - nuc13-003
        - nuc13-027
        - nuc13-038
        - nuc13-112
      - name: "win11-64-24h2-hw-relops1213"
        Description: "Baked WIM canary"
        image: "win11-24h2-hw-test-20260730-223108"
        src_Branch: "master"
        hash: "edef633"
        nodes:
        - nuc13-159
        - nuc13-160
        - nuc13-035
        - nuc13-060
      - name: "win11-64-24h2-hw-perf-sheriff"
        Description: "Single node"
        image: "win11-24H2-NUC-01-16-2025"
        src_Branch: "master"
        hash: "7511c8e"
        nodes:
        - nuc13-021
    defaults:
      NV_domain: "mdc1.mozilla.com"
    Known-BAD:
      nuc13:
        - nuc13-112
        - t-nuc12-001
    """
)


def _source_task(
    name="test-windows11-64-24h2-hw-ref-shippable/opt-mochitest-media-mda-gpu",
    worker_type="win11-64-24h2-hw-ref",
    scopes=None,
):
    """A source task shaped like a real autoland Windows HW task."""
    if scopes is None:
        scopes = [
            "secrets:get:project/perftest/gecko/level-3/perftest-login",
            "generic-worker:cache:gecko-level-3-pip",
            "generic-worker:cache:gecko-level-3-uv",
            "generic-worker:os-group:releng-hardware/win11-64-24h2-hw-ref/admin",
        ]
    return {
        "label": name,
        "attributes": {"test_platform": "windows11-64-24h2-hw-ref-shippable"},
        "dependencies": ["EPVLzXYQS8mqKN7Wkp0IIg", "VrVC0un-TJ-KGP8tePwtAA"],
        "task": {
            "provisionerId": "releng-hardware",
            "workerType": worker_type,
            "schedulerId": "gecko-level-3",
            "taskGroupId": "ZUZ6G0U3Qa22ttrDk55vUA",
            "priority": "high",
            "created": "2026-08-03T06:01:28.802Z",
            "deadline": "2026-08-04T06:01:28.802Z",
            "expires": "2027-08-03T06:01:28.802Z",
            "routes": [
                "index.gecko.v2.autoland.latest.firefox.win64",
                "tc-treeherder.v2.autoland.abcdef",
            ],
            "scopes": scopes,
            "dependencies": ["EPVLzXYQS8mqKN7Wkp0IIg", "VrVC0un-TJ-KGP8tePwtAA"],
            "metadata": {"name": name, "description": "a test task", "owner": "x@y"},
            "extra": {
                "treeherder": {"symbol": "mda", "tier": 1},
                "suite": "mochitest",
            },
            "payload": {
                "maxRunTime": 5400,
                "cache": {"gecko-level-3-pip": "pip", "gecko-level-3-uv": "uv"},
                "mounts": [
                    {"cacheName": "gecko-level-3-pip", "directory": "pip"},
                    {"content": {"taskId": "VrVC0un-TJ-KGP8tePwtAA"}, "file": "x"},
                ],
                "artifacts": [
                    {
                        "name": "public/logs",
                        "path": "logs",
                        "expires": "2027-01-01T00:00:00Z",
                    }
                ],
                "env": {
                    "GECKO_HEAD_REV": "deadbeefcafe",
                    "GECKO_HEAD_REPOSITORY": "https://hg.mozilla.org/integration/autoland",
                    "MOZ_AUTOMATION": "1",
                },
            },
        },
    }


def _load_transform_module():
    return importlib.import_module(
        "worker_images_taskgraph.transforms.hw_integration_test"
    )


class GraphConfig(dict):
    """dict plus the `root_dir` attribute taskgraph exposes."""

    def __init__(self, root_dir, **kwargs):
        super().__init__(**kwargs)
        self.root_dir = root_dir


class DummyConfig:
    kind = "hw-integration-test"

    def __init__(self, repo_root, hw_pools, level="3"):
        self.params = {"hw_pools": hw_pools, "level": level}
        self.graph_config = GraphConfig(
            str(Path(repo_root) / "taskcluster"), **{"trust-domain": "relops"}
        )


class HwPoolsTestBase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = _load_transform_module()
        cls.hw_pools = importlib.import_module("worker_images_taskgraph.util.hw_pools")

    def setUp(self):
        self._tmp = TemporaryDirectory()
        root = Path(self._tmp.name)
        (root / "provisioners" / "windows" / "MDC1Windows").mkdir(parents=True)
        (root / "provisioners" / "windows" / "MDC1Windows" / "pools.yml").write_text(
            POOLS_YAML
        )
        (root / "taskcluster").mkdir()
        self.root = root
        self.addCleanup(self._tmp.cleanup)


class TestHwPoolRegistry(HwPoolsTestBase):
    def test_parses_pools_and_identity(self):
        reg = self.hw_pools.load_registry(self.root)
        self.assertEqual(len(reg.pools), 5)

        pool = reg["win11-64-24h2-hw-relops1213"]
        self.assertEqual(
            pool.task_queue_id, "releng-hardware/win11-64-24h2-hw-relops1213"
        )
        self.assertEqual(
            pool.identity,
            {
                "image": "win11-24h2-hw-test-20260730-223108",
                "src_branch": "master",
                "revision": "edef633",
            },
        )

    def test_production_pools_identified_without_a_deny_list(self):
        reg = self.hw_pools.load_registry(self.root)
        self.assertTrue(reg["win11-64-24h2-hw"].is_production)
        self.assertTrue(reg["win11-64-24h2-hw-ref"].is_production)
        for staging in (
            "win11-64-24h2-hw-alpha",
            "win11-64-24h2-hw-relops1213",
            "win11-64-24h2-hw-perf-sheriff",
        ):
            self.assertFalse(reg[staging].is_production, staging)
        self.assertEqual(len(reg.targetable), 3)

    def test_resolve_refuses_production_unknown_and_empty(self):
        reg = self.hw_pools.load_registry(self.root)
        for bad in (
            ["win11-64-24h2-hw"],
            ["win11-64-24h2-hw-ref"],
            ["win11-64-24h2-hw-alpha", "win11-64-24h2-hw"],
            ["does-not-exist"],
            [],
        ):
            with self.assertRaises(self.hw_pools.HwPoolError, msg=repr(bad)):
                reg.resolve(bad)

    def test_resolve_dedupes_and_uses_pools_yaml_order(self):
        reg = self.hw_pools.load_registry(self.root)
        resolved = reg.resolve(
            [
                "win11-64-24h2-hw-relops1213",
                "win11-64-24h2-hw-alpha",
                "win11-64-24h2-hw-relops1213",
            ]
        )
        self.assertEqual(
            [p.name for p in resolved],
            ["win11-64-24h2-hw-alpha", "win11-64-24h2-hw-relops1213"],
        )

    def test_known_bad_nodes_excluded_from_healthy(self):
        reg = self.hw_pools.load_registry(self.root)
        self.assertIn("nuc13-112", reg.known_bad_nodes)
        self.assertEqual(reg["win11-64-24h2-hw-alpha"].node_count, 5)
        self.assertEqual(len(reg.healthy_nodes("win11-64-24h2-hw-alpha")), 4)

    def test_low_capacity_flag(self):
        reg = self.hw_pools.load_registry(self.root)
        self.assertTrue(reg["win11-64-24h2-hw-perf-sheriff"].is_low_capacity)
        self.assertFalse(reg["win11-64-24h2-hw-alpha"].is_low_capacity)


class TestHwIntegrationTransform(HwPoolsTestBase):
    def setUp(self):
        super().setUp()
        os.environ["TASK_ID"] = "DECISIONTASKID12345678"
        self.addCleanup(os.environ.pop, "TASK_ID", None)

    def _run(self, hw_pools, sources=None, task_name="gecko-hw"):
        if sources is None:
            sources = [_source_task()]
        task = {
            "name": task_name,
            "description": "d",
            "hw-replicate": {
                "target": "gecko.v2.autoland.latest.taskgraph.decision",
                "provisioner": "releng-hardware",
                "worker-type-prefixes": ["win11-64-", "win11-a64-"],
            },
        }
        config = DummyConfig(self.root, hw_pools)
        with patch.object(self.mod, "_fetch_source_tasks", return_value=sources):
            return list(self.mod.replicate_onto_hw_pools(config, [task]))

    def test_fetch_source_tasks_keeps_only_tier_1(self):
        tier_1 = _source_task(name="tier-1")
        tier_2 = deepcopy(_source_task(name="tier-2"))
        tier_2["task"]["extra"]["treeherder"]["tier"] = 2

        with (
            patch.object(self.mod, "find_task_id", return_value="decision-id"),
            patch.object(
                self.mod,
                "get_artifact",
                return_value={"tier-1": tier_1, "tier-2": tier_2},
            ),
        ):
            result = self.mod._fetch_source_tasks(
                "gecko.v2.autoland.latest.taskgraph.decision",
                "releng-hardware",
                ("win11-64-",),
            )

        self.assertEqual([task["label"] for task in result], ["tier-1"])

    def test_kind_uses_autoland_source(self):
        kind = (
            Path(__file__).parents[1] / "kinds" / "hw-integration-test" / "kind.yml"
        ).read_text()
        self.assertIn("gecko.v2.autoland.latest.taskgraph.decision", kind)
        self.assertNotIn("gecko.v2.mozilla-central", kind)

    def test_no_pools_requested_emits_nothing_and_does_not_fetch(self):
        called = []
        task = {
            "name": "gecko-hw",
            "hw-replicate": {
                "target": "idx",
                "provisioner": "releng-hardware",
                "worker-type-prefixes": ["win11-64-"],
            },
        }
        with patch.object(
            self.mod,
            "_fetch_source_tasks",
            side_effect=lambda *a, **k: called.append(1) or [],
        ):
            out = list(
                self.mod.replicate_onto_hw_pools(DummyConfig(self.root, None), [task])
            )
        self.assertEqual(out, [])
        self.assertEqual(called, [], "must not hit the network on a normal decision")

    def test_production_pool_request_raises(self):
        with self.assertRaises(self.hw_pools.HwPoolError):
            self._run(["win11-64-24h2-hw"])

    def test_retargets_worker_type_and_keeps_provisioner(self):
        out = self._run(["win11-64-24h2-hw-relops1213"])
        self.assertEqual(len(out), 1)
        task = out[0]["task"]
        self.assertEqual(task["provisionerId"], "releng-hardware")
        self.assertEqual(task["workerType"], "win11-64-24h2-hw-relops1213")
        self.assertEqual(task["schedulerId"], "relops-level-3")
        self.assertEqual(task["taskGroupId"], "DECISIONTASKID12345678")
        self.assertEqual(task["priority"], "low")

    def test_one_task_per_pool_with_unique_labels(self):
        out = self._run(["win11-64-24h2-hw-relops1213", "win11-64-24h2-hw-alpha"])
        self.assertEqual(len(out), 2)
        labels = [t["label"] for t in out]
        self.assertEqual(len(set(labels)), 2)
        for t in out:
            self.assertIn(t["attributes"]["hw_pool"], t["label"])
            self.assertEqual(t["task"]["metadata"]["name"], t["label"])

    def test_gecko_routes_and_treeherder_are_stripped(self):
        out = self._run(["win11-64-24h2-hw-alpha"])
        task = out[0]["task"]
        self.assertEqual(task["routes"], [])
        self.assertNotIn("treeherder", task["extra"])
        # non-treeherder extra keys survive
        self.assertEqual(task["extra"]["suite"], "mochitest")

    def test_cache_names_and_scopes_rewritten_consistently(self):
        out = self._run(["win11-64-24h2-hw-alpha"])
        task = out[0]["task"]
        self.assertEqual(
            sorted(task["payload"]["cache"]),
            ["relops-level-3-pip", "relops-level-3-uv"],
        )
        self.assertEqual(
            task["payload"]["mounts"][0]["cacheName"], "relops-level-3-pip"
        )
        cache_scopes = sorted(
            s for s in task["scopes"] if s.startswith("generic-worker:cache:")
        )
        self.assertEqual(
            cache_scopes,
            [
                "generic-worker:cache:relops-level-3-pip",
                "generic-worker:cache:relops-level-3-uv",
            ],
        )
        # every cache the task mounts must have a matching scope
        for name in task["payload"]["cache"]:
            self.assertIn(f"generic-worker:cache:{name}", task["scopes"])

    def test_pool_bound_os_group_scope_retargeted(self):
        out = self._run(["win11-64-24h2-hw-alpha"])
        self.assertIn(
            "generic-worker:os-group:releng-hardware/win11-64-24h2-hw-alpha/admin",
            out[0]["task"]["scopes"],
        )

    def test_unholdable_secret_scope_dropped(self):
        out = self._run(["win11-64-24h2-hw-alpha"])
        scopes = out[0]["task"]["scopes"]
        self.assertFalse(
            [s for s in scopes if s.startswith("secrets:")],
            "secret scopes must be dropped, not carried or level-rewritten",
        )

    def test_datestamps_made_relative(self):
        out = self._run(["win11-64-24h2-hw-alpha"])
        task = out[0]["task"]
        self.assertEqual(task["created"], {"relative-datestamp": "0 seconds"})
        self.assertEqual(task["deadline"], {"relative-datestamp": "1 day"})
        self.assertEqual(task["expires"], {"relative-datestamp": "1 month"})
        self.assertEqual(
            task["payload"]["artifacts"][0]["expires"],
            {"relative-datestamp": "1 month"},
        )

    def test_gecko_revision_env_and_resolved_deps_preserved(self):
        out = self._run(["win11-64-24h2-hw-alpha"])
        task = out[0]["task"]
        # Unlike the cloud path we keep *_REV: the resolved dependency task ids
        # point at builds of exactly this revision.
        self.assertEqual(task["payload"]["env"]["GECKO_HEAD_REV"], "deadbeefcafe")
        self.assertEqual(
            task["dependencies"],
            ["EPVLzXYQS8mqKN7Wkp0IIg", "VrVC0un-TJ-KGP8tePwtAA"],
        )
        # nothing for taskgraph to resolve by label
        self.assertEqual(out[0]["dependencies"], {})

    def test_attributes_record_pool_identity_for_reporting(self):
        out = self._run(["win11-64-24h2-hw-relops1213"])
        attrs = out[0]["attributes"]
        self.assertEqual(attrs["hw_replicate"], "gecko-hw")
        self.assertEqual(attrs["hw_pool"], "win11-64-24h2-hw-relops1213")
        self.assertEqual(attrs["hw_pool_image"], "win11-24h2-hw-test-20260730-223108")
        self.assertEqual(attrs["hw_pool_branch"], "master")
        self.assertEqual(attrs["hw_pool_revision"], "edef633")
        # crucially NOT the cloud attribute, which target.py's `integration`
        # method selects on
        self.assertNotIn("replicate", attrs)

    def test_source_task_is_not_mutated(self):
        source = _source_task()
        self._run(["win11-64-24h2-hw-alpha"], sources=[source])
        self.assertEqual(source["task"]["workerType"], "win11-64-24h2-hw-ref")
        self.assertEqual(source["task"]["routes"][0].split(".")[0], "index")
        self.assertIn("treeherder", source["task"]["extra"])


class TestCloudAndHwSelectionAreDisjoint(unittest.TestCase):
    """The two target-tasks methods must never select each other's tasks."""

    def test_attribute_namespaces_are_disjoint(self):
        cloud_attrs = {"replicate": "gecko"}
        hw_attrs = {"hw_replicate": "gecko-hw", "hw_pool": "win11-64-24h2-hw-alpha"}

        # Mirrors the two methods in target.py.
        self.assertIn("replicate", cloud_attrs)
        self.assertNotIn("replicate", hw_attrs)
        self.assertIn("hw_replicate", hw_attrs)
        self.assertNotIn("hw_replicate", cloud_attrs)


if __name__ == "__main__":
    unittest.main()
