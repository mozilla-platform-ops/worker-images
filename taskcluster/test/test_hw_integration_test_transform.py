import datetime
import importlib
import json
import os
import sys
import textwrap
import types
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

# Shaped like pools.yml: two production pools, three staging, one Known-BAD.
POOLS_YAML = textwrap.dedent(
    """\
    ---
    pools:
      - name: "win11-64-24h2-hw"
        Description: "Production"
        image: "win11-24H2-NUC-01-16-2025"
        src_Organisation: "mozilla-platform-ops"
        src_Repository: "ronin_puppet"
        src_Branch: "master"
        hash: "655bf64"
        secret_date: "02-24-2026"
        domain_suffix: "wintest2.releng.mdc1.mozilla.com"
        nodes:
        - nuc13-004
        - nuc13-005
      - name: "win11-64-24h2-hw-ref"
        Description: "Production reference"
        image: "win11-24H2-NUC-01-16-2025"
        src_Branch: "master"
        hash: "655bf64"
        domain_suffix: "wintest2.releng.mdc1.mozilla.com"
        nodes:
        - t-nuc12-004
      - name: "win11-64-24h2-hw-ref-alpha"
        Description: "Staging reference"
        image: "win11-24H2-NUC-01-16-2025"
        src_Branch: "master"
        hash: "655bf64"
        domain_suffix: "wintest2.releng.mdc1.mozilla.com"
        nodes:
        - t-nuc12-005
      - name: "win11-64-24h2-hw-alpha"
        Description: "Staging"
        image: "win11-24H2-NUC-01-16-2025"
        src_Branch: "RELOPS-2402-fleetbench"
        hash: "74e8909"
        domain_suffix: "wintest2.releng.mdc1.mozilla.com"
        nodes:
        - nuc13-001
        - nuc13-003
        - nuc13-027
        - nuc13-038
        - nuc13-112
      - name: "win11-64-24h2-hw-relops1213"
        Description: "Baked WIM canary"
        dev: "nuc-wim-pipeline"
        image: "win11-24h2-hw-test-20260730-223108"
        src_Branch: "master"
        hash: "edef633"
        domain_suffix: "wintest2.releng.mdc1.mozilla.com"
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
        domain_suffix: "wintest2.releng.mdc1.mozilla.com"
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


OS_INTEGRATION_INDEX = (
    "gecko.v2.mozilla-central.latest.taskgraph.decision-os-integration"
)
PUSH_INDEX = "gecko.v2.mozilla-central.latest.taskgraph.decision"


def _source_task(
    name="test-windows11-64-24h2-shippable/opt-browsertime-benchmark-firefox-speedometer3",
    worker_type="win11-64-24h2-hw",
    scopes=None,
    kind="browsertime",
):
    """A source task shaped like a real mozilla-central Windows HW task."""
    if scopes is None:
        scopes = [
            "secrets:get:project/perftest/gecko/level-3/perftest-login",
            "generic-worker:cache:gecko-level-3-pip",
            "generic-worker:cache:gecko-level-3-uv",
            f"generic-worker:os-group:releng-hardware/{worker_type}/admin",
        ]
    return {
        "label": name,
        "kind": kind,
        "attributes": {"test_platform": "windows11-64-24h2-shippable/opt"},
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
                "index.gecko.v2.mozilla-central.latest.firefox.win64",
                "tc-treeherder.v2.mozilla-central.abcdef",
            ],
            "scopes": scopes,
            "dependencies": ["EPVLzXYQS8mqKN7Wkp0IIg", "VrVC0un-TJ-KGP8tePwtAA"],
            "metadata": {"name": name, "description": "a test task", "owner": "x@y"},
            "extra": {"treeherder": {"symbol": "mda"}, "suite": "mochitest"},
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
                    "GECKO_HEAD_REPOSITORY": "https://hg.mozilla.org/mozilla-central",
                    "MOZ_AUTOMATION": "1",
                },
            },
        },
    }


def _load_transform_module():
    """Stub taskgraph as test_integration_test_transform.py does.

    hw_pools is left real -- it only needs PyYAML, so it gets genuine coverage.
    """
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
    setattr(util_taskcluster_module, "find_task_id", lambda _: "stub-decision-id")
    setattr(util_taskcluster_module, "get_artifact", lambda *_: {})
    # Default: no pushlog-id route, so nothing walks back to an earlier push.
    # Tests that care replace `mod._earlier_pushes` or this.
    setattr(util_taskcluster_module, "get_task_definition", lambda _: {"routes": []})
    # Default: every dependency completed. Tests that care replace
    # `mod._dependency_states` instead of reaching through this.
    setattr(
        util_taskcluster_module,
        "status_task_batched",
        lambda ids: {i: {"state": "completed"} for i in ids},
    )

    sys.modules["taskgraph"] = taskgraph_module
    sys.modules["taskgraph.transforms"] = transforms_module
    sys.modules["taskgraph.transforms.base"] = base_module
    sys.modules["taskgraph.util"] = util_module
    sys.modules["taskgraph.util.taskcluster"] = util_taskcluster_module

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

    def __init__(self, repo_root, hw_pools, level="3", hw_tests=None, hw_repeat=None):
        self.params = {
            "hw_pools": hw_pools,
            "hw_tests": hw_tests,
            "hw_repeat": hw_repeat,
            "level": level,
        }
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
        self.assertEqual(len(reg.pools), 6)

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
        self.assertEqual(pool.dev_branch, "nuc-wim-pipeline")
        self.assertEqual(
            pool.fqdn("nuc13-159"), "nuc13-159.wintest2.releng.mdc1.mozilla.com"
        )

    def test_production_pools_identified_without_a_deny_list(self):
        reg = self.hw_pools.load_registry(self.root)
        self.assertTrue(reg["win11-64-24h2-hw"].is_production)
        self.assertTrue(reg["win11-64-24h2-hw-ref"].is_production)
        for staging in (
            "win11-64-24h2-hw-alpha",
            "win11-64-24h2-hw-ref-alpha",
            "win11-64-24h2-hw-relops1213",
            "win11-64-24h2-hw-perf-sheriff",
        ):
            self.assertFalse(reg[staging].is_production, staging)
        self.assertEqual(len(reg.targetable), 4)

    def test_source_worker_type_is_the_pool_being_staged(self):
        reg = self.hw_pools.load_registry(self.root)
        expected = {
            # a production pool stages itself
            "win11-64-24h2-hw": "win11-64-24h2-hw",
            "win11-64-24h2-hw-ref": "win11-64-24h2-hw-ref",
            "win11-64-24h2-hw-alpha": "win11-64-24h2-hw",
            "win11-64-24h2-hw-relops1213": "win11-64-24h2-hw",
            # `-perf-sheriff` must not be read as a `-ref` variant, nor the
            # other way round for `-ref-alpha`
            "win11-64-24h2-hw-perf-sheriff": "win11-64-24h2-hw",
            "win11-64-24h2-hw-ref-alpha": "win11-64-24h2-hw-ref",
        }
        for name, counterpart in expected.items():
            self.assertEqual(reg[name].source_worker_type, counterpart, name)

    def test_pool_name_off_convention_has_no_counterpart(self):
        HwPool = self.hw_pools.HwPool
        for name in ("nuc13-scratch", "win11-64-24h2", "macosx-1500-hw-alpha"):
            pool = HwPool(name=name)
            self.assertIsNone(pool.source_worker_type, name)
            self.assertFalse(pool.is_production, name)

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

    def test_resolve_refuses_a_pool_it_cannot_map_to_a_worker_type(self):
        reg = self.hw_pools.HwPoolRegistry(
            pools={"nuc13-scratch": self.hw_pools.HwPool(name="nuc13-scratch")},
            known_bad_nodes=frozenset(),
        )
        with self.assertRaises(self.hw_pools.HwPoolError):
            reg.resolve(["nuc13-scratch"])

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

    def _stub_fetch(self, per_index):
        """Serve canned task lists per target index, grouped as the real fetch is.

        Returns the list the stub appends each fetched index to, so a test can
        assert an index was never downloaded.
        """
        fetched = []

        def fetch(index, provisioner):
            fetched.append(index)
            by_worker_type = {}
            labels = {}
            for source in per_index.get(index, []):
                task = source["task"]
                for dep in task.get("dependencies", []):
                    labels.setdefault(dep, f"fetch-{dep}")
                if task["provisionerId"] != provisioner:
                    continue
                by_worker_type.setdefault(task["workerType"], []).append(source)
            return {"by_worker_type": by_worker_type, "labels": labels}

        self.mod._fetch_source_tasks = fetch
        return fetched

    def _run(self, hw_pools, sources=None, task_name="gecko-hw", per_index=None):
        if per_index is None:
            per_index = {
                OS_INTEGRATION_INDEX: [_source_task()] if sources is None else sources
            }
        self.fetched = self._stub_fetch(per_index)
        task = {
            "name": task_name,
            "description": "d",
            "hw-replicate": {
                "targets": [OS_INTEGRATION_INDEX, PUSH_INDEX],
                "provisioner": "releng-hardware",
            },
        }
        config = DummyConfig(self.root, hw_pools)
        return list(self.mod.replicate_onto_hw_pools(config, [task]))

    def test_no_pools_requested_emits_nothing_and_does_not_fetch(self):
        fetched = self._stub_fetch({})
        task = {
            "name": "gecko-hw",
            "hw-replicate": {
                "targets": [OS_INTEGRATION_INDEX],
                "provisioner": "releng-hardware",
            },
        }
        out = list(
            self.mod.replicate_onto_hw_pools(DummyConfig(self.root, None), [task])
        )
        self.assertEqual(out, [])
        self.assertEqual(fetched, [], "must not hit the network on a normal decision")

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
        self.assertEqual(source["task"]["workerType"], "win11-64-24h2-hw")
        self.assertEqual(source["task"]["routes"][0].split(".")[0], "index")
        self.assertIn("treeherder", source["task"]["extra"])


class TestPoolToWorkerTypeMatching(HwPoolsTestBase):
    """A pool only runs the tasks of the production pool it stages."""

    def setUp(self):
        super().setUp()
        os.environ["TASK_ID"] = "DECISIONTASKID12345678"
        self.addCleanup(os.environ.pop, "TASK_ID", None)
        self.hw = _source_task(
            name="test-windows11-64-24h2-shippable/opt-talos-webgl",
            worker_type="win11-64-24h2-hw",
        )
        self.hw_ref = _source_task(
            name="test-windows11-64-24h2-hw-ref-shippable/opt-mochitest-media-mda-gpu",
            worker_type="win11-64-24h2-hw-ref",
        )
        self.macos = _source_task(
            name="test-macosx1500-64-shippable/opt-talos-webgl",
            worker_type="gecko-t-osx-1500-m4",
        )

    def _run(self, hw_pools, per_index, drop_kinds=("perftest",)):
        fetched = []

        def fetch(index, provisioner):
            fetched.append(index)
            by_worker_type = {}
            labels = {}
            for source in per_index.get(index, []):
                task = source["task"]
                for dep in task.get("dependencies", []):
                    labels.setdefault(dep, f"fetch-{dep}")
                if task["provisionerId"] != provisioner:
                    continue
                by_worker_type.setdefault(task["workerType"], []).append(source)
            return {"by_worker_type": by_worker_type, "labels": labels}

        self.mod._fetch_source_tasks = fetch
        task = {
            "name": "gecko-hw",
            "description": "d",
            "hw-replicate": {
                "targets": [OS_INTEGRATION_INDEX, PUSH_INDEX],
                "provisioner": "releng-hardware",
                "fallback-drop-kinds": list(drop_kinds),
            },
        }
        out = list(
            self.mod.replicate_onto_hw_pools(DummyConfig(self.root, hw_pools), [task])
        )
        return out, fetched

    def test_pool_gets_only_its_counterparts_tasks(self):
        per_index = {OS_INTEGRATION_INDEX: [self.hw, self.hw_ref, self.macos]}
        out, _ = self._run(["win11-64-24h2-hw-alpha"], per_index)
        self.assertEqual(
            [t["attributes"]["hw_source_label"] for t in out],
            ["test-windows11-64-24h2-shippable/opt-talos-webgl"],
        )
        self.assertEqual(
            out[0]["attributes"]["hw_source_worker_type"], "win11-64-24h2-hw"
        )

    def test_reference_pool_gets_only_reference_tasks(self):
        per_index = {OS_INTEGRATION_INDEX: [self.hw, self.hw_ref]}
        out, _ = self._run(["win11-64-24h2-hw-ref-alpha"], per_index)
        self.assertEqual(len(out), 1)
        self.assertEqual(
            out[0]["attributes"]["hw_source_worker_type"], "win11-64-24h2-hw-ref"
        )
        # ...and it is aimed at the ref pool, not the pool it was copied from
        self.assertEqual(out[0]["task"]["workerType"], "win11-64-24h2-hw-ref-alpha")
        self.assertIn(
            "generic-worker:os-group:releng-hardware/win11-64-24h2-hw-ref-alpha/admin",
            out[0]["task"]["scopes"],
        )

    def test_falls_through_to_next_index_when_counterpart_absent(self):
        per_index = {
            OS_INTEGRATION_INDEX: [self.hw],
            PUSH_INDEX: [self.hw, self.hw_ref],
        }
        out, fetched = self._run(
            ["win11-64-24h2-hw-alpha", "win11-64-24h2-hw-ref-alpha"], per_index
        )
        by_pool = {t["attributes"]["hw_pool"]: t["attributes"] for t in out}
        self.assertEqual(
            by_pool["win11-64-24h2-hw-alpha"]["hw_source_index"], OS_INTEGRATION_INDEX
        )
        self.assertEqual(
            by_pool["win11-64-24h2-hw-ref-alpha"]["hw_source_index"], PUSH_INDEX
        )

    def test_larger_index_not_fetched_when_first_one_suffices(self):
        per_index = {
            OS_INTEGRATION_INDEX: [self.hw],
            PUSH_INDEX: [self.hw, self.hw_ref],
        }
        out, fetched = self._run(["win11-64-24h2-hw-alpha"], per_index)
        self.assertEqual(len(out), 1)
        self.assertEqual(
            fetched,
            [OS_INTEGRATION_INDEX],
            "the full push graph is large; don't download it needlessly",
        )

    def test_each_index_fetched_at_most_once_across_pools(self):
        per_index = {OS_INTEGRATION_INDEX: [self.hw]}
        out, fetched = self._run(
            ["win11-64-24h2-hw-alpha", "win11-64-24h2-hw-relops1213"], per_index
        )
        self.assertEqual(len(out), 2)
        self.assertEqual(fetched, [OS_INTEGRATION_INDEX])

    def test_pool_with_no_tasks_anywhere_raises(self):
        # `-hw-ref` scheduled nowhere: silently emitting zero tasks would report
        # a green run that tested nothing.
        per_index = {OS_INTEGRATION_INDEX: [self.hw], PUSH_INDEX: [self.hw]}
        with self.assertRaises(self.hw_pools.HwPoolError) as ctx:
            self._run(["win11-64-24h2-hw-ref-alpha"], per_index)
        self.assertIn("win11-64-24h2-hw-ref", str(ctx.exception))

    def test_the_ml_perftest_suite_is_dropped_when_falling_back(self):
        # Nothing in mozilla-central curates an os-integration set for `-hw-ref`,
        # so the fall-back is every task its counterpart runs: on 2026-08-19 that
        # was 4 platform tests and 12 `ml-*` perftests, 10.6h across two nodes.
        ml = [
            _source_task(
                name=f"perftest-windows11-24h2-ref-{name}",
                worker_type="win11-64-24h2-hw-ref",
                kind="perftest",
            )
            for name in ("ml-perf", "ml-summarizer-perf", "perftest-accessibility")
        ]
        per_index = {
            OS_INTEGRATION_INDEX: [self.hw],
            PUSH_INDEX: [self.hw, self.hw_ref, *ml],
        }
        out, _ = self._run(["win11-64-24h2-hw-ref-alpha"], per_index)
        self.assertEqual(
            [t["attributes"]["hw_source_label"] for t in out],
            ["test-windows11-64-24h2-hw-ref-shippable/opt-mochitest-media-mda-gpu"],
        )

    def test_the_curated_index_keeps_its_perftests(self):
        # os-integration names service-worker itself, so a pool it covers gets
        # that task; the trim is for indexes that curate nothing.
        service_worker = _source_task(
            name="perftest-windows11-24h2-service-worker",
            worker_type="win11-64-24h2-hw",
            kind="perftest",
        )
        per_index = {OS_INTEGRATION_INDEX: [self.hw, service_worker]}
        out, _ = self._run(["win11-64-24h2-hw-alpha"], per_index)
        self.assertIn(
            "perftest-windows11-24h2-service-worker",
            [t["attributes"]["hw_source_label"] for t in out],
        )

    def test_a_counterpart_with_nothing_but_dropped_kinds_raises(self):
        # Emitting zero tasks would report a green run that tested nothing.
        ml = _source_task(
            name="perftest-windows11-24h2-ref-ml-perf",
            worker_type="win11-64-24h2-hw-ref",
            kind="perftest",
        )
        per_index = {OS_INTEGRATION_INDEX: [self.hw], PUSH_INDEX: [self.hw, ml]}
        with self.assertRaises(self.hw_pools.HwPoolError) as ctx:
            self._run(["win11-64-24h2-hw-ref-alpha"], per_index)
        self.assertIn("perftest", str(ctx.exception))

    def test_no_configured_kinds_means_no_trimming(self):
        ml = _source_task(
            name="perftest-windows11-24h2-ref-ml-perf",
            worker_type="win11-64-24h2-hw-ref",
            kind="perftest",
        )
        per_index = {OS_INTEGRATION_INDEX: [self.hw], PUSH_INDEX: [self.hw_ref, ml]}
        out, _ = self._run(["win11-64-24h2-hw-ref-alpha"], per_index, drop_kinds=())
        self.assertEqual(len(out), 2)

    def test_macos_hardware_tasks_never_match_a_windows_pool(self):
        per_index = {
            OS_INTEGRATION_INDEX: [self.macos],
            PUSH_INDEX: [self.macos],
        }
        with self.assertRaises(self.hw_pools.HwPoolError):
            self._run(["win11-64-24h2-hw-alpha"], per_index)


def _speedometer_sources():
    """The two speedometer3 tasks a `-hw` pool's counterpart schedules, plus
    company to filter out."""
    prefix = "test-windows11-64-24h2-shippable/opt-browsertime"
    return [
        _source_task(name=f"{prefix}-benchmark-firefox-speedometer3"),
        _source_task(name=f"{prefix}-benchmark-custom-car-speedometer3"),
        _source_task(name=f"{prefix}-tp6-essential-firefox-amazon"),
        _source_task(name="test-windows11-64-24h2-shippable/opt-talos-webgl"),
    ]


class TestTestFilterAndRepeat(HwPoolsTestBase):
    """What the speedometer workflow relies on: pick tasks by name, run them N
    times."""

    def setUp(self):
        super().setUp()
        os.environ["TASK_ID"] = "DECISIONTASKID12345678"
        self.addCleanup(os.environ.pop, "TASK_ID", None)
        self.sources = _speedometer_sources()

    def _run(self, hw_tests=None, hw_repeat=None, sources=None):
        sources = self.sources if sources is None else sources
        self.mod._fetch_source_tasks = lambda index, provisioner: {
            "labels": {},
            "by_worker_type": {"win11-64-24h2-hw": sources},
        }
        task = {
            "name": "gecko-hw",
            "description": "d",
            "hw-replicate": {
                "targets": [OS_INTEGRATION_INDEX],
                "provisioner": "releng-hardware",
            },
        }
        config = DummyConfig(
            self.root,
            ["win11-64-24h2-hw-alpha"],
            hw_tests=hw_tests,
            hw_repeat=hw_repeat,
        )
        return list(self.mod.replicate_onto_hw_pools(config, [task]))

    def _names(self, out):
        return [t["attributes"]["hw_source_label"] for t in out]

    def test_no_filter_runs_everything_once(self):
        out = self._run()
        self.assertEqual(len(out), 4)
        self.assertEqual({t["attributes"]["hw_run_count"] for t in out}, {1})

    def test_filter_selects_by_substring(self):
        out = self._run(hw_tests=["speedometer"])
        self.assertEqual(len(out), 2)
        self.assertTrue(all("speedometer" in n for n in self._names(out)))

    def test_filter_is_case_insensitive(self):
        self.assertEqual(len(self._run(hw_tests=["SpeedOmeter"])), 2)

    def test_narrower_filter_excludes_the_other_browser(self):
        out = self._run(hw_tests=["firefox-speedometer"])
        self.assertEqual(
            self._names(out),
            [
                "test-windows11-64-24h2-shippable/opt-browsertime-"
                "benchmark-firefox-speedometer3"
            ],
        )

    def test_several_filters_union(self):
        out = self._run(hw_tests=["firefox-speedometer", "talos-webgl"])
        self.assertEqual(len(out), 2)

    def test_filter_matching_nothing_raises_and_lists_what_there_was(self):
        with self.assertRaises(self.hw_pools.HwPoolError) as ctx:
            self._run(hw_tests=["jetstream"])
        message = str(ctx.exception)
        self.assertIn("jetstream", message)
        # the message has to be actionable: it names what could have been run
        self.assertIn("talos-webgl", message)

    def test_repeat_yields_distinct_labels_and_task_ids(self):
        out = self._run(hw_tests=["firefox-speedometer"], hw_repeat=5)
        self.assertEqual(len(out), 5)
        labels = [t["label"] for t in out]
        self.assertEqual(len(set(labels)), 5, "identical labels would collide")
        self.assertEqual(
            sorted(t["attributes"]["hw_run_index"] for t in out), [1, 2, 3, 4, 5]
        )
        for t in out:
            self.assertEqual(t["attributes"]["hw_run_count"], 5)
            self.assertEqual(t["task"]["metadata"]["name"], t["label"])
            self.assertTrue(
                t["label"].endswith(f"-run{t['attributes']['hw_run_index']}")
            )

    def test_repeat_copies_are_otherwise_identical(self):
        out = self._run(hw_tests=["firefox-speedometer"], hw_repeat=3)
        payloads = {json.dumps(t["task"]["payload"], sort_keys=True) for t in out}
        self.assertEqual(len(payloads), 1, "repeats must differ only by label")

    def test_repeat_of_one_leaves_the_label_alone(self):
        out = self._run(hw_tests=["firefox-speedometer"], hw_repeat=1)
        self.assertNotIn("-run", out[0]["label"].rsplit("speedometer3", 1)[-1])

    def test_repeat_out_of_range_raises(self):
        for bad in (0, -1, self.hw_pools.MAX_REPEAT + 1, 2.5, "5"):
            with self.assertRaises(self.hw_pools.HwPoolError, msg=repr(bad)):
                self._run(hw_tests=["firefox-speedometer"], hw_repeat=bad)

    def test_filter_and_repeat_multiply(self):
        out = self._run(hw_tests=["speedometer"], hw_repeat=4)
        self.assertEqual(len(out), 8)


class TestBlockedDependencies(HwPoolsTestBase):
    """A replicated task keeps mozilla-central's concrete dependency ids, so an
    upstream that already failed can never be satisfied."""

    def setUp(self):
        super().setUp()
        os.environ["TASK_ID"] = "DECISIONTASKID12345678"
        self.addCleanup(os.environ.pop, "TASK_ID", None)

    def _run(self, sources, dep_states):
        self.mod._fetch_source_tasks = lambda index, provisioner: {
            "labels": {},
            "by_worker_type": {"win11-64-24h2-hw": sources},
        }
        self.mod._dependency_states = lambda dep_ids: {
            d: dep_states.get(d, "completed") for d in dep_ids
        }
        self.addCleanup(
            setattr,
            self.mod,
            "_dependency_states",
            self.mod._dependency_states,
        )
        task = {
            "name": "gecko-hw",
            "description": "d",
            "hw-replicate": {
                "targets": [OS_INTEGRATION_INDEX],
                "provisioner": "releng-hardware",
            },
        }
        config = DummyConfig(self.root, ["win11-64-24h2-hw-alpha"])
        return list(self.mod.replicate_onto_hw_pools(config, [task]))

    def _with_deps(self, name, deps):
        source = _source_task(name=name)
        source["task"]["dependencies"] = deps
        return source

    def test_task_with_a_failed_upstream_is_skipped(self):
        # The real case: toolchain-win64-custom-car failed, so the custom-car
        # speedometer copy sat unscheduled until its deadline.
        good = self._with_deps("firefox-speedometer3", ["build" + "0" * 17])
        bad = self._with_deps("custom-car-speedometer3", ["car" + "0" * 19])
        out = self._run([good, bad], {"car" + "0" * 19: "failed"})
        self.assertEqual(
            [t["attributes"]["hw_source_label"] for t in out], ["firefox-speedometer3"]
        )

    def test_exception_and_unknown_upstreams_also_block(self):
        for state in ("exception", "unknown"):
            source = self._with_deps("a-test", ["dep" + "0" * 19])
            with self.assertRaises(self.hw_pools.HwPoolError, msg=state):
                self._run([source], {"dep" + "0" * 19: state})

    def test_unresolved_upstreams_are_waited_on_not_skipped(self):
        # A graph still in flight is normal; these will resolve.
        for state in ("unscheduled", "pending", "running"):
            source = self._with_deps("a-test", ["dep" + "0" * 19])
            out = self._run([source], {"dep" + "0" * 19: state})
            self.assertEqual(len(out), 1, state)

    def test_every_task_blocked_raises_rather_than_scheduling_nothing(self):
        source = self._with_deps("only-test", ["dep" + "0" * 19])
        with self.assertRaises(self.hw_pools.HwPoolError) as ctx:
            self._run([source], {"dep" + "0" * 19: "failed"})
        self.assertIn("only-test", str(ctx.exception))

    def test_the_all_blocked_refusal_is_the_retryable_one(self):
        # Only this refusal has a chance of a different answer from another
        # graph, so only this one is a subclass the retry loop catches.
        self.assertTrue(issubclass(self.mod.HwUpstreamError, self.hw_pools.HwPoolError))


PUSH_INDEX = "gecko.v2.mozilla-central.latest.taskgraph.decision"


class TestWalkBackToAnEarlierPush(HwPoolsTestBase):
    """The newest push's build may be cancelled or still running. Run
    32768047542 reached no verdict because build-win64-shippable/opt was
    cancelled 23 minutes after its own decision; push 45161 had a completed
    build and would have served."""

    def setUp(self):
        super().setUp()
        os.environ["TASK_ID"] = "DECISIONTASKID12345678"
        self.addCleanup(os.environ.pop, "TASK_ID", None)

    def _run(self, graphs, dep_states, walkback=3, pushes=None):
        """`graphs` maps a source label to its task list, newest push first."""
        labels = list(graphs)

        def fetch_source(index, provisioner):
            return {
                "labels": {},
                "decision": f"decision-for-{labels[0]}",
                "by_worker_type": {"win11-64-24h2-hw": graphs[labels[0]]},
            }

        def fetch_decision(decision_task_id, provisioner, label):
            return {
                "labels": {},
                "decision": decision_task_id,
                "by_worker_type": {"win11-64-24h2-hw": graphs[label]},
            }

        for name in ("_fetch_source_tasks", "_fetch_decision_tasks", "_earlier_pushes"):
            self.addCleanup(setattr, self.mod, name, getattr(self.mod, name))
        self.mod._fetch_source_tasks = fetch_source
        self.mod._fetch_decision_tasks = fetch_decision
        self.mod._earlier_pushes = lambda decision, limit: (
            pushes if pushes is not None else [(45161, "decision-for-pushlog-id 45161")]
        )[:limit]
        self.mod._dependency_states = lambda dep_ids: {
            d: dep_states.get(d, "completed") for d in dep_ids
        }
        task = {
            "name": "gecko-hw",
            "description": "d",
            "hw-replicate": {
                "targets": [PUSH_INDEX],
                "provisioner": "releng-hardware",
                "blocked-walkback": walkback,
            },
        }
        config = DummyConfig(self.root, ["win11-64-24h2-hw-alpha"])
        return list(self.mod.replicate_onto_hw_pools(config, [task]))

    def _with_deps(self, name, deps):
        source = _source_task(name=name)
        source["task"]["dependencies"] = deps
        return source

    def test_a_dead_build_falls_back_to_the_previous_push(self):
        out = self._run(
            {
                PUSH_INDEX: [self._with_deps("a-test", ["dead" + "0" * 18])],
                "pushlog-id 45161": [self._with_deps("a-test", ["live" + "0" * 18])],
            },
            {"dead" + "0" * 18: "exception"},
        )
        self.assertEqual([t["attributes"]["hw_source_label"] for t in out], ["a-test"])

    def test_the_fallback_graph_is_recorded_as_the_source(self):
        out = self._run(
            {
                PUSH_INDEX: [self._with_deps("a-test", ["dead" + "0" * 18])],
                "pushlog-id 45161": [self._with_deps("a-test", ["live" + "0" * 18])],
            },
            {"dead" + "0" * 18: "exception"},
        )
        self.assertIn("45161", out[0]["attributes"]["hw_source_index"])

    def test_a_walkback_of_zero_keeps_the_old_refusal(self):
        with self.assertRaises(self.hw_pools.HwPoolError):
            self._run(
                {PUSH_INDEX: [self._with_deps("a-test", ["dead" + "0" * 18])]},
                {"dead" + "0" * 18: "exception"},
                walkback=0,
            )

    def test_an_earlier_push_that_is_also_dead_keeps_walking(self):
        out = self._run(
            {
                PUSH_INDEX: [self._with_deps("a-test", ["dead" + "0" * 18])],
                "pushlog-id 45161": [self._with_deps("a-test", ["also" + "0" * 18])],
                "pushlog-id 45160": [self._with_deps("a-test", ["live" + "0" * 18])],
            },
            {"dead" + "0" * 18: "exception", "also" + "0" * 18: "failed"},
            pushes=[
                (45161, "decision-for-pushlog-id 45161"),
                (45160, "decision-for-pushlog-id 45160"),
            ],
        )
        self.assertEqual(len(out), 1)

    def test_running_out_of_pushes_raises_the_original_refusal(self):
        with self.assertRaises(self.hw_pools.HwPoolError) as ctx:
            self._run(
                {
                    PUSH_INDEX: [self._with_deps("a-test", ["dead" + "0" * 18])],
                    "pushlog-id 45161": [
                        self._with_deps("a-test", ["also" + "0" * 18])
                    ],
                },
                {"dead" + "0" * 18: "exception", "also" + "0" * 18: "failed"},
            )
        self.assertIn("a-test", str(ctx.exception))

    def test_nothing_to_walk_to_keeps_the_refusal(self):
        with self.assertRaises(self.hw_pools.HwPoolError):
            self._run(
                {PUSH_INDEX: [self._with_deps("a-test", ["dead" + "0" * 18])]},
                {"dead" + "0" * 18: "exception"},
                pushes=[],
            )

    def test_a_graph_with_no_pushlog_route_yields_no_pushes(self):
        # A cron graph carries no pushlog-id route, and an older cron graph would
        # be a week older rather than a push older. The stubbed
        # get_task_definition returns no routes, which is that case.
        self.assertEqual(self.mod._earlier_pushes("some-decision", 3), [])

    def test_a_zero_limit_asks_the_index_nothing(self):
        self.assertEqual(self.mod._earlier_pushes("some-decision", 0), [])

    def test_the_pushlog_route_is_recognised(self):
        match = self.mod._PUSHLOG_ROUTE_RE.match(
            "index.gecko.v2.mozilla-central.pushlog-id.45154.decision"
        )
        self.assertEqual(match["prefix"], "gecko.v2.mozilla-central")
        self.assertEqual(match["push"], "45154")
        self.assertIsNone(
            self.mod._PUSHLOG_ROUTE_RE.match(
                "index.gecko.v2.mozilla-central.revision.abc.taskgraph.decision"
            )
        )


CANARY = "public/cft-cd-win64-canary.tar.bz2"
EXPIRED_FETCH = "MlQ-iRxpSTmvwuR4uSg2-A"
LIVE_FETCH = "JoV-a2X0RIGmnd6p07sXlQ"
DAILY = "gecko.v2.mozilla-central.latest.taskgraph.decision-custom-car-perf-testing"


class TestExpiredFetches(HwPoolsTestBase):
    """A replicated task keeps mozilla-central's fetch task ids, and the
    Chrome-for-Testing artifacts live two days against a weekly cron. On
    2026-08-19 that cost every repeat of custom-car-speedometer3 eight minutes
    of hardware time and an HTTP 410."""

    def setUp(self):
        super().setUp()
        self.now = datetime.datetime.now(datetime.timezone.utc)
        self.live = self.now + datetime.timedelta(days=1, hours=8)
        self.dead = self.now - datetime.timedelta(hours=17)

    def _source(self, name="custom-car-speedometer3", fetch_task=EXPIRED_FETCH):
        source = _source_task(name=name)
        source["task"]["dependencies"] = [fetch_task, "OTHERDEP" + "0" * 14]
        source["task"]["payload"]["env"] = {
            "MOZ_FETCHES": json.dumps(
                [
                    {"artifact": CANARY, "extract": True, "task": fetch_task},
                    {
                        "artifact": "public/build/node.tar.zst",
                        "extract": True,
                        "task": "OTHERDEP" + "0" * 14,
                    },
                ]
            )
        }
        return source

    def _stub_artifacts(self, expiries):
        """expiries maps task id -> {artifact: datetime}."""
        self.mod._artifact_expiries = lambda task_id: expiries.get(task_id, {})

    def _repair(self, sources, expiries, graphs=None):
        self._stub_artifacts(expiries)
        graphs = graphs or {}
        self.mod.find_task_id = lambda index: f"decision-of-{index}"
        self.mod.get_artifact = lambda decision, artifact: graphs.get(
            decision.replace("decision-of-", ""), {}
        )
        pool = self.hw_pools.load_registry(self.root)["win11-64-24h2-hw-alpha"]
        return self.mod._repair_fetches(
            sources,
            pool,
            {EXPIRED_FETCH: "fetch-win64-cft-cd-canary"},
            [DAILY],
        )

    def test_a_live_fetch_is_left_alone(self):
        source = self._source()
        out = self._repair(
            [source],
            {
                EXPIRED_FETCH: {CANARY: self.live},
                "OTHERDEP" + "0" * 14: {"public/build/node.tar.zst": self.live},
            },
        )
        self.assertEqual(len(out), 1)
        fetches = json.loads(out[0]["task"]["payload"]["env"]["MOZ_FETCHES"])
        self.assertEqual(fetches[0]["task"], EXPIRED_FETCH, "no needless rewrite")
        self.assertNotIn("hw-integration", out[0]["task"].get("extra", {}))

    def test_an_expired_fetch_is_repointed_at_a_live_copy(self):
        source = self._source()
        out = self._repair(
            [source],
            {
                EXPIRED_FETCH: {CANARY: self.dead},
                LIVE_FETCH: {CANARY: self.live},
                "OTHERDEP" + "0" * 14: {"public/build/node.tar.zst": self.live},
            },
            graphs={DAILY: {"fetch-win64-cft-cd-canary": LIVE_FETCH}},
        )
        self.assertEqual(len(out), 1)
        fetches = json.loads(out[0]["task"]["payload"]["env"]["MOZ_FETCHES"])
        self.assertEqual(fetches[0]["task"], LIVE_FETCH)
        self.assertEqual(fetches[0]["artifact"], CANARY, "same artifact, new task")
        # the dependency has to move with it, or the task waits on a dead task
        self.assertIn(LIVE_FETCH, out[0]["task"]["dependencies"])
        self.assertNotIn(EXPIRED_FETCH, out[0]["task"]["dependencies"])
        # and the substitution is recorded on the task, not just in the log
        recorded = out[0]["task"]["extra"]["hw-integration"]["substituted-fetches"]
        self.assertEqual(recorded[0]["replacement_task"], LIVE_FETCH)
        self.assertEqual(recorded[0]["source_index"], DAILY)

    def test_an_artifact_expiring_mid_run_counts_as_expired(self):
        source = self._source()
        soon = self.now + datetime.timedelta(hours=1)
        out = self._repair(
            [source],
            {
                EXPIRED_FETCH: {CANARY: soon},
                LIVE_FETCH: {CANARY: self.live},
                "OTHERDEP" + "0" * 14: {"public/build/node.tar.zst": self.live},
            },
            graphs={DAILY: {"fetch-win64-cft-cd-canary": LIVE_FETCH}},
        )
        fetches = json.loads(out[0]["task"]["payload"]["env"]["MOZ_FETCHES"])
        self.assertEqual(fetches[0]["task"], LIVE_FETCH, "a run queues for hours")

    def test_a_replacement_that_is_also_expired_is_not_used(self):
        source = self._source()
        with self.assertRaises(self.hw_pools.HwPoolError):
            self._repair(
                [source],
                {
                    EXPIRED_FETCH: {CANARY: self.dead},
                    LIVE_FETCH: {CANARY: self.dead},
                    "OTHERDEP" + "0" * 14: {"public/build/node.tar.zst": self.live},
                },
                graphs={DAILY: {"fetch-win64-cft-cd-canary": LIVE_FETCH}},
            )

    def test_a_task_with_no_live_copy_is_skipped_not_run(self):
        doomed = self._source(name="custom-car-speedometer3")
        fine = self._source(
            name="firefox-speedometer3", fetch_task="LIVEDEP" + "0" * 15
        )
        out = self._repair(
            [doomed, fine],
            {
                EXPIRED_FETCH: {CANARY: self.dead},
                "LIVEDEP" + "0" * 15: {CANARY: self.live},
                "OTHERDEP" + "0" * 14: {"public/build/node.tar.zst": self.live},
            },
            graphs={DAILY: {}},
        )
        self.assertEqual(
            [s["task"]["metadata"]["name"] for s in out], ["firefox-speedometer3"]
        )

    def test_a_missing_artifact_is_treated_as_expired(self):
        source = self._source()
        with self.assertRaises(self.hw_pools.HwPoolError):
            self._repair(
                [source],
                {
                    EXPIRED_FETCH: {},  # the task exists; the artifact is gone
                    "OTHERDEP" + "0" * 14: {"public/build/node.tar.zst": self.live},
                },
                graphs={DAILY: {}},
            )

    def test_a_task_without_fetches_is_untouched(self):
        source = _source_task(name="talos-webgl")
        out = self._repair([source], {})
        self.assertEqual(out, [source])


class TestCloudAndHwSelectionAreDisjoint(unittest.TestCase):
    """The two target-tasks methods must never select each other's tasks."""

    def test_attribute_namespaces_do_not_overlap(self):
        cloud_attrs = {"replicate": "gecko"}
        hw_attrs = {"hw_replicate": "gecko-hw", "hw_pool": "win11-64-24h2-hw-alpha"}

        # mirrors target.py::integration and hw_target.py::hw_integration
        self.assertIn("replicate", cloud_attrs)
        self.assertNotIn("replicate", hw_attrs)
        self.assertIn("hw_replicate", hw_attrs)
        self.assertNotIn("hw_replicate", cloud_attrs)


if __name__ == "__main__":
    unittest.main()
