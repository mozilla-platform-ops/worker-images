# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

"""Tests for ci/run-hw-os-integration.py.

Loaded by path, as the script itself loads hw_pools, because `ci/` is not a
package and the script's own dependencies (taskcluster, requests) are only
installed where it runs.
"""

import datetime
import importlib.util
import os
import sys
import tempfile
import types
import unittest
import unittest.mock
from pathlib import Path

RUNNER = (
    Path(__file__).resolve().parent.parent.parent / "ci" / "run-hw-os-integration.py"
)

GROUP = "DECISIONGROUPID1234567"


class FakeRestFailure(Exception):
    pass


def _load_runner():
    taskcluster_module = types.ModuleType("taskcluster")
    taskcluster_module.exceptions = types.SimpleNamespace(
        TaskclusterRestFailure=FakeRestFailure
    )
    sys.modules["taskcluster"] = taskcluster_module

    requests_module = types.ModuleType("requests")
    requests_module.RequestException = Exception
    sys.modules["requests"] = requests_module

    spec = importlib.util.spec_from_file_location("hw_runner", RUNNER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _task(task_id, state, name=None, worker=None):
    status = {"taskId": task_id, "state": state}
    if worker is not None:
        status["runs"] = [{"runId": 0, "workerId": worker}]
    return {"status": status, "task": {"metadata": {"name": name or task_id}}}


def _perfherder(value, replicates=(), name="speedometer3"):
    """Shaped like the real public/test_info/perfherder-data.json."""
    return {
        "framework": {"name": "browsertime"},
        "suites": [
            {
                "name": name,
                "value": value,
                "unit": "score",
                "lowerIsBetter": False,
                "replicates": list(replicates),
                "subtests": [{"name": "Charts-chartjs/total", "value": 39.5}],
            }
        ],
    }


class RunnerTestBase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = _load_runner()


class TestTally(RunnerTestBase):
    """The monitored group is rooted at the decision task, which is not a
    result."""

    def test_decision_task_excluded_and_tracked_separately(self):
        counts = self.mod.tally([_task(GROUP, "failed")], GROUP)
        self.assertEqual(counts["total"], 0)
        self.assertEqual(counts["decision"], "failed")
        self.assertEqual(counts["pending"], 0)

    def test_green_run_counts_only_replicated_tasks(self):
        tasks = [_task(GROUP, "completed")] + [
            _task(f"task{i:018d}", "completed") for i in range(11)
        ]
        counts = self.mod.tally(tasks, GROUP)
        self.assertEqual((counts["total"], counts["completed"]), (11, 11))
        self.assertEqual(counts["decision"], "completed")

    def test_states_are_bucketed(self):
        tasks = [
            _task(GROUP, "completed"),
            _task("a" * 22, "completed"),
            _task("b" * 22, "failed"),
            _task("c" * 22, "exception"),
            _task("d" * 22, "unscheduled"),
        ]
        counts = self.mod.tally(tasks, GROUP)
        self.assertEqual(counts["total"], 4)
        self.assertEqual(counts["completed"], 1)
        self.assertEqual(counts["failed"], 1)
        self.assertEqual(counts["exception"], 1)
        self.assertEqual(counts["pending"], 1)

    def test_running_decision_is_not_a_finished_empty_run(self):
        counts = self.mod.tally([_task(GROUP, "running")], GROUP)
        self.assertIn(counts["decision"], self.mod.PENDING_STATES)

    def test_summary_table_skips_the_decision_task(self):
        tasks = [_task(GROUP, "completed"), _task("a" * 22, "completed")]
        self.assertEqual(len(self.mod.replicated_tasks(tasks, GROUP)), 1)


class TestBlockedTasks(RunnerTestBase):
    """Run 31516844982 sat 3.5h past its last result waiting on a task whose
    upstream had failed, then reported a timeout. The decision now refuses to
    create such a task, but an upstream still running at decision time can fail
    afterwards, so the monitor has to notice too."""

    def _queue(self, dep_states):
        class Queue:
            def status(_self, task_id):
                if task_id not in dep_states:
                    raise FakeRestFailure("404")
                return {"status": {"state": dep_states[task_id]}}

        return Queue()

    def _unscheduled(self, task_id, deps):
        task = _task(task_id, "unscheduled")
        task["task"]["dependencies"] = deps
        return task

    def test_task_waiting_on_a_failed_upstream_is_blocked(self):
        tasks = [self._unscheduled("stuck", ["build", "toolchain"])]
        blocked = self.mod.find_blocked(
            self._queue({"build": "completed", "toolchain": "failed"}), tasks, {}
        )
        self.assertEqual(blocked, {"stuck": {"toolchain": "failed"}})

    def test_task_waiting_on_a_running_upstream_is_not_blocked(self):
        tasks = [self._unscheduled("waiting", ["build"])]
        self.assertEqual(
            self.mod.find_blocked(self._queue({"build": "running"}), tasks, {}), {}
        )

    def test_only_unscheduled_tasks_are_checked(self):
        running = _task("busy", "running")
        running["task"]["dependencies"] = ["toolchain"]
        self.assertEqual(
            self.mod.find_blocked(self._queue({"toolchain": "failed"}), [running], {}),
            {},
        )

    def test_a_blocked_task_is_not_rechecked(self):
        calls = []

        class CountingQueue:
            def status(_self, task_id):
                calls.append(task_id)
                return {"status": {"state": "failed"}}

        tasks = [self._unscheduled("stuck", ["toolchain"])]
        known = self.mod.find_blocked(CountingQueue(), tasks, {})
        self.mod.find_blocked(CountingQueue(), tasks, known)
        self.assertEqual(calls, ["toolchain"], "status should be asked once")

    def test_blocked_tasks_stop_counting_as_pending(self):
        tasks = [
            _task(GROUP, "completed"),
            _task("done" + "0" * 18, "completed"),
            self._unscheduled("stuck", ["toolchain"]),
        ]
        counts = self.mod.tally(tasks, GROUP, {"stuck"})
        self.assertEqual(counts["pending"], 0, "waiting on it is waiting on nothing")
        self.assertEqual(counts["blocked"], 1)
        self.assertEqual(counts["completed"], 1)
        self.assertEqual(counts["total"], 2)

    def test_without_the_block_it_would_be_pending_forever(self):
        tasks = [_task(GROUP, "completed"), self._unscheduled("stuck", ["toolchain"])]
        self.assertEqual(self.mod.tally(tasks, GROUP)["pending"], 1)

    def test_dependency_states_that_can_still_resolve(self):
        for state in ("unscheduled", "pending", "running", "completed"):
            self.assertNotIn(state, self.mod.DEPENDENCY_DEAD_STATES, state)


class TestScores(RunnerTestBase):
    """Reading the score out of the task, which is why this run needs no
    Treeherder route."""

    def _run_with(self, blobs, states=None, workers=None, nodes=None):
        """`blobs` maps task id -> perfherder blob, or None for no artifact."""
        states = states or {}
        workers = workers or {}

        class Queue:
            def getLatestArtifact(_self, task_id, name):
                assert name == self.mod.PERFHERDER_ARTIFACT
                blob = blobs.get(task_id)
                if blob is None:
                    raise FakeRestFailure("404 no such artifact")
                return blob

        runs = [
            {
                "pool": "win11-64-24h2-hw-perf-debug",
                "task_group_id": GROUP,
                "nodes": nodes or [],
                "tasks": [_task(GROUP, "completed", worker="cloud-decision")]
                + [
                    _task(
                        task_id,
                        states.get(task_id, "completed"),
                        worker=workers.get(task_id, "nuc13-024"),
                    )
                    for task_id in blobs
                ],
            }
        ]
        self.mod.collect_scores(Queue(), runs)
        return runs

    def _values(self, runs, suite="speedometer3"):
        return self.mod.sample_values(runs[0]["scores"][suite]["samples"])

    def test_one_value_per_completed_task(self):
        runs = self._run_with(
            {
                "run1": _perfherder(24.5, [24.3, 24.6]),
                "run2": _perfherder(25.5, [25.4, 25.6]),
                "run3": _perfherder(23.5),
            }
        )
        entry = runs[0]["scores"]["speedometer3"]
        self.assertEqual(sorted(self._values(runs)), [23.5, 24.5, 25.5])
        self.assertEqual(entry["unit"], "score")
        self.assertFalse(entry["lower_is_better"])
        replicates = [r for s in entry["samples"] for r in s["replicates"]]
        self.assertEqual(len(replicates), 4)

    def test_failed_tasks_and_tasks_without_data_contribute_nothing(self):
        runs = self._run_with(
            {
                "run1": _perfherder(24.5),
                "noperf": None,
                "broken": _perfherder(99.9),
            },
            states={"broken": "failed"},
        )
        self.assertEqual(self._values(runs), [24.5])

    def test_no_scores_leaves_the_key_off_and_the_section_out(self):
        runs = self._run_with({"noperf": None})
        self.assertNotIn("scores", runs[0])
        self.assertEqual(self.mod.score_summary_lines(runs), [])

    def test_several_suites_are_kept_apart(self):
        runs = self._run_with(
            {
                "run1": _perfherder(24.5),
                "run2": _perfherder(120.0, name="jetstream2"),
            }
        )
        self.assertEqual(sorted(runs[0]["scores"]), ["jetstream2", "speedometer3"])

    def test_summarize_reports_spread_not_just_a_mean(self):
        stats = self.mod.summarize([24.5, 25.5, 23.0, 26.0])
        self.assertEqual(stats["n"], 4)
        self.assertAlmostEqual(stats["mean"], 24.75)
        self.assertAlmostEqual(stats["median"], 25.0)
        self.assertEqual((stats["min"], stats["max"]), (23.0, 26.0))
        self.assertGreater(stats["stdev"], 0)
        self.assertAlmostEqual(stats["cv"], 100 * stats["stdev"] / stats["mean"])

    def test_summarize_of_a_single_run_has_no_stdev(self):
        stats = self.mod.summarize([24.5])
        self.assertEqual(stats["stdev"], 0.0)
        self.assertEqual(stats["cv"], 0.0)

    def test_summary_table_renders_the_pool_and_direction(self):
        runs = self._run_with({"run1": _perfherder(24.5), "run2": _perfherder(25.5)})
        table = "\n".join(self.mod.score_summary_lines(runs))
        self.assertIn("### Scores", table)
        self.assertIn("win11-64-24h2-hw-perf-debug", table)
        self.assertIn("speedometer3 ↑", table)
        self.assertIn("25.00", table)
        self.assertIn("per run: 24.50 (nuc13-024), 25.50 (nuc13-024)", table)


class TestWorkerBreakdown(RunnerTestBase):
    """A pool mean of three NUCs hides the one that is slow."""

    def _scored(self, samples, nodes=None, suite="speedometer3"):
        """A run whose scores are already collected, so a test can state the
        (worker, value) pairs directly."""
        return [
            {
                "pool": "win11-64-24h2-hw-perf-debug",
                "task_group_id": GROUP,
                "nodes": nodes or [],
                "scores": {
                    suite: {
                        "unit": "score",
                        "lower_is_better": False,
                        "samples": [
                            {
                                "worker": worker,
                                "value": value,
                                "task_id": f"task{i}",
                                "replicates": [],
                            }
                            for i, (worker, value) in enumerate(samples)
                        ],
                    }
                },
            }
        ]

    def test_worker_is_read_from_the_last_run(self):
        task = _task("a" * 22, "completed", worker="nuc13-024")
        task["status"]["runs"].append({"runId": 1, "workerId": "nuc13-059"})
        self.assertEqual(self.mod.task_worker(task), "nuc13-059")

    def test_worker_missing_is_not_a_crash(self):
        self.assertEqual(self.mod.task_worker(_task("a" * 22, "completed")), "unknown")

    def test_samples_group_by_worker(self):
        grouped = self.mod.by_worker(
            [
                {"worker": "nuc13-059", "value": 1.0},
                {"worker": "nuc13-024", "value": 2.0},
                {"worker": "nuc13-059", "value": 3.0},
            ]
        )
        self.assertEqual(list(grouped), ["nuc13-024", "nuc13-059"])
        self.assertEqual([s["value"] for s in grouped["nuc13-059"]], [1.0, 3.0])

    def test_collect_scores_records_the_node_that_produced_each_value(self):
        blobs = {"run1": _perfherder(24.5), "run2": _perfherder(20.0)}
        runs = TestScores._run_with(
            self,
            blobs,
            workers={"run1": "nuc13-024", "run2": "nuc13-119"},
        )
        samples = runs[0]["scores"]["speedometer3"]["samples"]
        self.assertEqual(
            {s["worker"]: s["value"] for s in samples},
            {"nuc13-024": 24.5, "nuc13-119": 20.0},
        )

    def test_table_has_a_row_per_worker_with_delta(self):
        runs = self._scored(
            [("nuc13-024", 25.0), ("nuc13-024", 25.0), ("nuc13-059", 25.0)]
        )
        table = "\n".join(self.mod.worker_summary_lines(runs))
        self.assertIn("#### By worker", table)
        self.assertIn("`nuc13-024`", table)
        self.assertIn("`nuc13-059`", table)
        # every node is on the pool mean here, so nothing is flagged
        self.assertNotIn("⚠️", table)
        self.assertIn("+0.0%", table)

    def test_slow_node_is_flagged_and_its_healthy_peers_are_not(self):
        # nuc13-119 is 20% down on the others: the case this table exists for.
        # Comparing against the pool mean would flag all three, since one slow
        # node drags that mean down and leaves the healthy pair reading fast.
        runs = self._scored(
            [
                ("nuc13-024", 25.0),
                ("nuc13-059", 25.0),
                ("nuc13-119", 20.0),
                ("nuc13-119", 20.0),
            ]
        )
        table = "\n".join(self.mod.worker_summary_lines(runs))
        self.assertIn("`nuc13-119` ⚠️", table)
        self.assertNotIn("`nuc13-024` ⚠️", table)
        self.assertNotIn("`nuc13-059` ⚠️", table)
        self.assertIn("-20.0%", table)
        self.assertIn("nuc13-119** (win11-64-24h2-hw-perf-debug) is -20.0%", table)

    def test_peer_baseline_is_unmoved_by_one_bad_node(self):
        self.assertEqual(self.mod.peer_baseline([25.0, 25.0, 20.0]), 25.0)
        self.assertEqual(self.mod.peer_baseline([]), 0.0)
        # with two nodes that disagree there is no majority to appeal to, so
        # both sit off the midpoint and both get flagged
        runs = self._scored([("nuc13-024", 25.0), ("nuc13-119", 20.0)])
        table = "\n".join(self.mod.worker_summary_lines(runs))
        self.assertIn("`nuc13-024` ⚠️", table)
        self.assertIn("`nuc13-119` ⚠️", table)

    def test_a_node_within_the_noise_floor_is_not_flagged(self):
        runs = self._scored([("nuc13-024", 25.0), ("nuc13-059", 24.5)])
        self.assertNotIn("⚠️", "\n".join(self.mod.worker_summary_lines(runs)))

    def test_only_nodes_that_produced_a_result_get_a_row(self):
        # What this replaced: idle nodes were worked out per suite, so a pool of
        # 41 nodes running each test once rendered one row and forty "no result"
        # rows per suite -- eleven suites of that in run 32180165353.
        runs = self._scored(
            [("nuc13-024", 25.0)], nodes=["nuc13-024", "nuc13-059", "nuc13-119"]
        )
        table = "\n".join(self.mod.worker_summary_lines(runs))
        rows = [line for line in table.splitlines() if line.startswith("| win11")]
        self.assertEqual(len(rows), 1)
        self.assertIn("`nuc13-024`", rows[0])
        for node in ("nuc13-059", "nuc13-119"):
            self.assertNotIn(f"`{node}`", table)

    def test_a_node_missing_from_one_suite_is_not_idle(self):
        runs = self._scored([("nuc13-024", 25.0)], nodes=["nuc13-024", "nuc13-059"])
        runs[0]["scores"]["youtube-playback-hfr"] = {
            "unit": "score",
            "lower_is_better": True,
            "samples": [
                {
                    "worker": "nuc13-059",
                    "value": 0.5,
                    "task_id": "task9",
                    "replicates": [],
                }
            ],
        }
        self.assertEqual(self.mod.idle_nodes(runs[0]), [])
        self.assertEqual(self.mod.idle_note(runs[0]), "")

    def test_idle_nodes_are_named_when_the_run_had_work_for_all_of_them(self):
        runs = self._scored(
            [("nuc13-024", 25.0), ("nuc13-024", 25.0), ("nuc13-059", 25.0)],
            nodes=["nuc13-024", "nuc13-059", "nuc13-119"],
        )
        note = self.mod.idle_note(runs[0])
        self.assertIn("1 of 3", note)
        self.assertIn("nuc13-119", note)
        self.assertIn(f"- {note}", "\n".join(self.mod.worker_summary_lines(runs)))

    def test_an_uneven_split_is_counted_rather_than_named(self):
        # One result across three nodes: the idle two are arithmetic, not a fault.
        runs = self._scored(
            [("nuc13-024", 25.0)], nodes=["nuc13-024", "nuc13-059", "nuc13-119"]
        )
        note = self.mod.idle_note(runs[0])
        self.assertIn("2 of 3", note)
        self.assertIn("uneven split", note)
        self.assertNotIn("nuc13-119", note)

    def test_a_run_without_a_node_list_gets_no_note(self):
        runs = self._scored([("nuc13-024", 25.0)])
        self.assertEqual(self.mod.idle_note(runs[0]), "")

    def test_outlier_threshold_is_symmetric(self):
        self.assertTrue(self.mod.is_outlier(self.mod.WORKER_OUTLIER_PERCENT))
        self.assertTrue(self.mod.is_outlier(-self.mod.WORKER_OUTLIER_PERCENT))
        self.assertFalse(self.mod.is_outlier(self.mod.WORKER_OUTLIER_PERCENT - 0.1))

    def test_percent_delta_handles_a_zero_baseline(self):
        self.assertEqual(self.mod.percent_delta(1.0, 0.0), 0.0)

    def test_breakdown_is_part_of_the_score_section(self):
        runs = self._scored([("nuc13-024", 25.0), ("nuc13-119", 25.0)])
        section = "\n".join(self.mod.score_summary_lines(runs))
        self.assertIn("### Scores", section)
        self.assertIn("#### By worker", section)
        self.assertIn("25.00 (nuc13-024)", section)


POOLS_YAML = """
pools:
  - name: "win11-64-24h2-hw-alpha"
    Description: "NUC13 staging"
    image: "{image}"
    src_Organisation: "mozilla-platform-ops"
    src_Repository: "ronin_puppet"
    src_Branch: "master"
    hash: "{hash}"
    puppet_version: "8.10.0"
    openvox_version: "8.19.2"
    git_version: "2.50.0"
    secret_date: "02-24-2026"
    domain_suffix: "wintest2.releng.mdc1.mozilla.com"
    nodes:
{nodes}
"""


def _pools_yaml(
    image="win11-24H2-NUC-01-16-2025", hash="74e8909", nodes=("nuc13-024",)
):
    return POOLS_YAML.format(
        image=image, hash=hash, nodes="\n".join(f"    - {n}" for n in nodes)
    )


class _FakePool:
    """Enough of HwPool for the deployment-record code, which only reads these."""

    def __init__(self, name, dev_branch=None, deployment=None):
        self.name = name
        self.dev_branch = dev_branch
        self.nodes = ("nuc13-024",)
        self.deployment = deployment or {
            "image": "checkout-image",
            "src_branch": "master",
            "revision": "74e8909",
            "dev_branch": dev_branch,
        }
        self.identity = {
            key: self.deployment.get(key) for key in ("image", "src_branch", "revision")
        }
        self.config_url = "https://example/tree/74e8909"


class TestDeploymentDetails(RunnerTestBase):
    """pools.yml is the only record of what a hardware pool is running, so the
    run has to say which configuration produced its numbers."""

    POOL = "win11-64-24h2-hw-alpha"

    def _run(self, **overrides):
        deployment = {
            "description": "NUC13 staging",
            "image": "win11-24H2-NUC-01-16-2025",
            "src_organisation": "mozilla-platform-ops",
            "src_repository": "ronin_puppet",
            "src_branch": "master",
            "revision": "74e8909",
            "dev_branch": None,
            "puppet_version": "8.10.0",
            "openvox_version": "8.19.2",
            "git_version": "2.50.0",
            "secret_date": "02-24-2026",
            "domain_suffix": "wintest2.releng.mdc1.mozilla.com",
        }
        deployment.update(overrides)
        return [
            {
                "pool": self.POOL,
                "deployment": deployment,
                "config_url": (
                    "https://github.com/mozilla-platform-ops/ronin_puppet/tree/74e8909"
                ),
                "nodes": ["nuc13-024", "nuc13-059"],
            }
        ]

    def test_block_names_the_config_the_tasks_ran_on(self):
        block = "\n".join(self.mod.deployment_summary_lines(self._run()))
        self.assertIn("### Pool deployment", block)
        self.assertIn("| Pool | NUC13 staging |", block)
        self.assertIn("| WIM image | `win11-24H2-NUC-01-16-2025` |", block)
        # org, repo, branch and revision are one row, linking the tree that ran
        self.assertIn(
            "| Config | [mozilla-platform-ops/ronin_puppet @ master (74e8909)]"
            "(https://github.com/mozilla-platform-ops/ronin_puppet/tree/74e8909) |",
            block,
        )
        self.assertIn("| Nodes | 2 (`nuc13-024` … `nuc13-059`) |", block)

    def test_what_the_config_link_already_carries_is_not_a_row(self):
        """Four rows naming one tree, and five more of what that tree sets, is a
        table nobody reads. The link and the pre-flight log carry them."""
        runs = self._run(dev_branch="nuc-wim-pipeline")
        runs[0]["deployment_source"] = "nuc-wim-pipeline"
        block = "\n".join(self.mod.deployment_summary_lines(runs))
        for dropped in (
            "Config org",
            "Config repo",
            "Config branch",
            "Config revision",
            "Deploy branch (dev)",
            "Puppet",
            "OpenVox",
            "Git",
            "Secrets",
            "Domain",
        ):
            self.assertNotIn(f"| {dropped} |", block)
        # ...but the pre-flight log still says all of it, key=value
        logged = self.mod.deployment_log_lines(runs[0]["deployment"])
        self.assertIn("puppet_version=8.10.0", logged)
        self.assertIn("secret_date=02-24-2026", logged)
        self.assertIn("domain_suffix=wintest2.releng.mdc1.mozilla.com", logged)
        # and drift can still name any of them
        self.assertEqual(self.mod.DRIFT_LABELS["puppet_version"], "Puppet")
        self.assertEqual(self.mod.DRIFT_LABELS["dev_branch"], "Deploy branch (dev)")

    def test_the_config_row_survives_a_pin_it_cannot_link(self):
        # No revision means no tree URL; the branch is still worth printing.
        runs = self._run(revision=None)
        runs[0]["config_url"] = None
        block = "\n".join(self.mod.deployment_summary_lines(runs))
        self.assertIn(
            "| Config | `mozilla-platform-ops/ronin_puppet @ master` |", block
        )

    def test_a_field_pools_yaml_omits_is_left_out(self):
        block = "\n".join(
            self.mod.deployment_summary_lines(self._run(description=None))
        )
        self.assertNotIn("| Pool |", block)

    def test_a_dev_branch_pool_notes_that_the_details_came_from_the_branch(self):
        runs = self._run(dev_branch="nuc-wim-pipeline")
        runs[0]["deployment_source"] = "nuc-wim-pipeline"
        block = "\n".join(self.mod.deployment_summary_lines(runs))
        self.assertIn("[!NOTE]", block)
        self.assertIn("is on the dev option: `dev: nuc-wim-pipeline`", block)
        # the branch's pools.yml is a link, so the record can actually be read
        self.assertIn(
            "read from [that branch's `pools.yml`](https://github.com/"
            "mozilla-platform-ops/worker-images/blob/nuc-wim-pipeline/",
            block,
        )

    def test_the_dev_link_follows_the_repo_the_workflow_runs_in(self):
        with unittest.mock.patch.dict(
            os.environ, {"GITHUB_REPOSITORY": "someone/fork"}
        ):
            runs = self._run(dev_branch="wip")
            runs[0]["deployment_source"] = "wip"
            block = "\n".join(self.mod.deployment_summary_lines(runs))
        self.assertIn("https://github.com/someone/fork/blob/wip/", block)

    def test_an_unreadable_dev_branch_says_the_details_may_lag(self):
        runs = self._run(dev_branch="nuc-wim-pipeline")
        runs[0]["deployment_source"] = "main"
        block = "\n".join(self.mod.deployment_summary_lines(runs))
        self.assertIn("is on the dev option: `dev: nuc-wim-pipeline`", block)
        self.assertIn("could not be read", block)
        self.assertIn("may lag the hardware", block)

    def test_a_pool_without_a_dev_branch_says_nothing_about_branches(self):
        block = "\n".join(self.mod.deployment_summary_lines(self._run()))
        self.assertNotIn("[!NOTE]", block)
        self.assertNotIn("dev option", block)

    def test_a_dev_pool_reports_the_branch_record_not_the_checkout(self):
        # The live case on 2026-08-19: ref-alpha's deploy branch records a baked
        # WIM and a different ronin pin, and the branch is what is on the metal.
        checkout = _FakePool(
            "win11-64-24h2-hw-ref-alpha",
            dev_branch="nuc-wim-pipeline",
            deployment={
                "image": "win11-24H2-NUC-01-16-2025",
                "src_branch": "RELOPS-2467-xperf-dynamic-trace",
                "revision": "a22e7ac",
                "dev_branch": "nuc-wim-pipeline",
            },
        )
        snapshot = {
            "nuc-wim-pipeline": {
                checkout.name: {
                    "deployment": {
                        "image": "win11-24h2-hw-20260811-202701",
                        "src_branch": "wim-bake-role",
                        "revision": "48a8b9d4",
                        "dev_branch": None,
                    },
                    "config_url": "https://example/tree/48a8b9d4",
                    "nodes": ("t-nuc12-002",),
                }
            }
        }
        records = self.mod.deployment_records([checkout], "main", snapshot)
        record = records[checkout.name]
        self.assertEqual(record["source"], "nuc-wim-pipeline")
        self.assertEqual(record["deployment"]["image"], "win11-24h2-hw-20260811-202701")
        self.assertEqual(record["identity"]["revision"], "48a8b9d4")
        self.assertEqual(record["config_url"], "https://example/tree/48a8b9d4")
        # the branch's own copy has no `dev:` key; keep the flag that pointed here
        self.assertEqual(record["deployment"]["dev_branch"], "nuc-wim-pipeline")

    def test_a_pool_without_dev_is_read_from_the_checkout(self):
        pool = _FakePool("win11-64-24h2-hw-alpha")
        records = self.mod.deployment_records([pool], "main", {})
        self.assertEqual(records[pool.name]["source"], "main")
        self.assertEqual(records[pool.name]["deployment"]["image"], "checkout-image")

    def test_an_unreadable_dev_branch_falls_back_to_the_checkout(self):
        pool = _FakePool("win11-64-24h2-hw-ref-alpha", dev_branch="gone")
        records = self.mod.deployment_records([pool], "main", {})
        self.assertEqual(records[pool.name]["source"], "main")
        self.assertEqual(records[pool.name]["deployment"]["image"], "checkout-image")

    def test_refs_cover_the_checkout_and_every_dev_branch_once(self):
        pools = [
            _FakePool("a", dev_branch="feature"),
            _FakePool("b"),
            _FakePool("c", dev_branch="feature"),
        ]
        self.assertEqual(self.mod.deployment_refs(pools, "main"), ["main", "feature"])

    def test_no_deployment_means_no_section(self):
        self.assertEqual(self.mod.deployment_summary_lines([{"pool": self.POOL}]), [])

    def test_log_lines_skip_what_is_unset(self):
        lines = self.mod.deployment_log_lines(
            {"image": "win11", "dev_branch": None, "git_version": ""}
        )
        self.assertEqual(lines, ["image=win11"])


class TestDeploymentDrift(RunnerTestBase):
    """A pools.yml edit that lands mid-run splits the results across two
    configurations, which is worth shouting about."""

    POOL = "win11-64-24h2-hw-alpha"

    def _snapshot(self, image="win11-24H2-NUC-01-16-2025", nodes=("nuc13-024",)):
        return {
            "main": {
                self.POOL: {
                    "deployment": {"image": image, "revision": "74e8909"},
                    "nodes": tuple(nodes),
                }
            }
        }

    def test_a_changed_field_is_reported_with_both_values(self):
        changes = self.mod.compare_deployments(
            self._snapshot(), self._snapshot(image="win11-24H2-NUC-08-18-2026")
        )
        self.assertEqual(len(changes), 1)
        self.assertEqual(changes[0]["field"], "image")
        self.assertEqual(changes[0]["before"], "win11-24H2-NUC-01-16-2025")
        self.assertEqual(changes[0]["after"], "win11-24H2-NUC-08-18-2026")
        self.assertEqual(changes[0]["ref"], "main")

    def test_an_unchanged_snapshot_is_quiet(self):
        self.assertEqual(
            self.mod.compare_deployments(self._snapshot(), self._snapshot()), []
        )
        self.assertEqual(self.mod.drift_summary_lines([]), [])

    def test_nodes_joining_or_leaving_the_pool_are_reported(self):
        changes = self.mod.compare_deployments(
            self._snapshot(nodes=("nuc13-024", "nuc13-059")),
            self._snapshot(nodes=("nuc13-024", "nuc13-119")),
        )
        self.assertEqual([c["field"] for c in changes], ["nodes"])
        self.assertIn("added nuc13-119", changes[0]["after"])
        self.assertIn("removed nuc13-059", changes[0]["after"])

    def test_a_pool_deleted_mid_run_is_a_change(self):
        changes = self.mod.compare_deployments(self._snapshot(), {"main": {}})
        self.assertEqual(changes[0]["after"], "removed from pools.yml")

    def test_a_ref_that_could_not_be_reread_is_not_called_drift(self):
        # fetch_registry returning None must not read as "everything changed"
        self.assertEqual(self.mod.compare_deployments(self._snapshot(), {}), [])

    def test_the_caution_block_leads_the_summary(self):
        changes = self.mod.compare_deployments(
            self._snapshot(), self._snapshot(image="other")
        )
        lines = self.mod.drift_summary_lines(changes)
        self.assertEqual(lines[0], "> [!CAUTION]")
        self.assertIn("changed while this run was in flight", lines[1])
        table = "\n".join(lines)
        self.assertIn("| win11-64-24h2-hw-alpha | WIM image | `main` |", table)

    def test_summary_puts_the_caution_above_everything(self):
        changes = self.mod.compare_deployments(
            self._snapshot(), self._snapshot(image="other")
        )
        runs = [
            {
                "pool": self.POOL,
                "identity": {"image": "i", "src_branch": "b", "revision": "r"},
                "verdict": "✅ passed",
                "task_group_id": GROUP,
            }
        ]
        with tempfile.NamedTemporaryFile("r+", suffix=".md") as handle:
            os.environ["GITHUB_STEP_SUMMARY"] = handle.name
            try:
                self.mod.write_github_summary(runs, "https://tc.example", "", changes)
            finally:
                del os.environ["GITHUB_STEP_SUMMARY"]
            written = Path(handle.name).read_text()
        self.assertLess(written.index("[!CAUTION]"), written.index("| Pool | Image |"))
        self.assertTrue(written.startswith("## HW OS Integration Tests"))

    def test_snapshot_reads_each_ref_and_survives_a_failure(self):
        served = {
            self.mod.pools_yaml_url("owner/repo", "main"): _pools_yaml(),
            self.mod.pools_yaml_url("owner/repo", "dev-branch"): _pools_yaml(
                image="branch-image", nodes=("nuc13-024", "nuc13-059")
            ),
        }

        class Response:
            def __init__(self, text):
                self.text = text

            def raise_for_status(self):
                return None

        def fake_get(url, timeout=None):
            if url not in served:
                raise self.mod.requests.RequestException(f"404 {url}")
            return Response(served[url])

        original = getattr(self.mod.requests, "get", None)
        self.mod.requests.get = fake_get
        try:
            pools = [_FakePool(self.POOL, dev_branch="dev-branch")]
            refs = self.mod.deployment_refs(pools, "main")
            self.assertEqual(refs, ["main", "dev-branch"])
            snapshot = self.mod.snapshot_deployments(
                [self.POOL], "owner/repo", refs + ["gone"]
            )
            self.assertEqual(sorted(snapshot), ["dev-branch", "main"])
            self.assertEqual(
                snapshot["main"][self.POOL]["deployment"]["image"],
                "win11-24H2-NUC-01-16-2025",
            )
            # the dev branch's copy is a different record of the same pool, which
            # is the point of reading it separately
            self.assertEqual(
                snapshot["dev-branch"][self.POOL]["deployment"]["image"],
                "branch-image",
            )
            self.assertEqual(len(snapshot["dev-branch"][self.POOL]["nodes"]), 2)
        finally:
            if original is None:
                del self.mod.requests.get
            else:
                self.mod.requests.get = original


class _FakeQueue:
    """listTaskGroup over a script of responses, and a cancelTask nothing calls."""

    def __init__(self, responses):
        self.responses = list(responses)
        self.cancelled = []
        self.listed = 0

    def listTaskGroup(self, group):
        self.listed += 1
        return self.responses[min(self.listed - 1, len(self.responses) - 1)]

    def cancelTask(self, task_id):
        self.cancelled.append(task_id)


class TestWaitCeiling(RunnerTestBase):
    """GitHub cancels the job at 6h and the step summary dies with it -- run
    31516844982 did, at 6h00m34s. Waiting stops before that, with results."""

    def test_the_ceiling_leaves_time_to_write_the_summary(self):
        self.assertLessEqual(self.mod.WAIT_CEILING_SECONDS, int(5.75 * 3600))
        self.assertGreaterEqual(6 * 3600 - self.mod.WAIT_CEILING_SECONDS, 600)

    def test_a_wait_that_fits_is_left_alone(self):
        self.assertEqual(self.mod.wait_budget(3600, 0, in_actions=True), 3600)

    def test_a_six_hour_wait_is_trimmed_to_the_ceiling(self):
        self.assertEqual(
            self.mod.wait_budget(6 * 3600, 0, in_actions=True),
            self.mod.WAIT_CEILING_SECONDS,
        )

    def test_time_the_run_already_burned_comes_off_the_budget(self):
        # checkout, uv and pre-flight happen before the wait starts
        self.assertEqual(
            self.mod.wait_budget(6 * 3600, 900, in_actions=True),
            self.mod.WAIT_CEILING_SECONDS - 900,
        )

    def test_a_run_already_past_the_ceiling_waits_no_longer(self):
        self.assertEqual(self.mod.wait_budget(3600, 10 * 3600, in_actions=True), 0)

    def test_off_ci_there_is_nothing_to_be_cancelled_by(self):
        self.assertEqual(self.mod.wait_budget(8 * 3600, 0, in_actions=False), 8 * 3600)

    def test_the_budget_is_measured_from_the_start_of_the_run(self):
        started = "2026-08-19T12:00:00Z"
        now = datetime.datetime(2026, 8, 19, 12, 20, tzinfo=datetime.timezone.utc)
        with unittest.mock.patch.dict(os.environ, {"GITHUB_RUN_STARTED_AT": started}):
            self.assertEqual(self.mod.elapsed_since_run_start(now), 1200.0)

    def test_an_unusable_run_start_budgets_from_now_instead(self):
        for stamp in ("", "yesterday"):
            with unittest.mock.patch.dict(os.environ, {"GITHUB_RUN_STARTED_AT": stamp}):
                self.assertEqual(self.mod.elapsed_since_run_start(), 0.0)

    def test_running_out_of_wait_reads_the_group_once_more_and_leaves_it(self):
        # The last poll can be five minutes stale, so the tasks that landed in
        # that window are collected before the run gives up on them.
        queue = _FakeQueue(
            [{"tasks": [_task(GROUP, "completed"), _task("a" * 22, "running")]}]
        )
        run = {"pool": "win11-64-24h2-hw-alpha", "task_group_id": GROUP}
        self.mod.monitor(queue, [run], 0, "https://tc.example")
        self.assertEqual(queue.listed, 1, "the final reading is taken")
        self.assertTrue(run["timed_out"])
        self.assertEqual(run["counts"]["completed"], 0)
        self.assertEqual(run["counts"]["pending"], 1)
        self.assertEqual(queue.cancelled, [], "the tasks are Taskcluster's to finish")

    def test_tasks_that_landed_in_the_last_poll_gap_are_not_a_timeout(self):
        queue = _FakeQueue(
            [{"tasks": [_task(GROUP, "completed"), _task("a" * 22, "completed")]}]
        )
        run = {"pool": "win11-64-24h2-hw-alpha", "task_group_id": GROUP}
        self.mod.monitor(queue, [run], 0, "https://tc.example")
        self.assertTrue(run["done"])
        self.assertNotIn("timed_out", run)

    def test_the_summary_says_they_outran_the_wait_and_links_the_group(self):
        runs = [
            {
                "pool": "win11-64-24h2-hw-alpha",
                "task_group_id": GROUP,
                "timed_out": True,
                "waited": int(5.75 * 3600),
                "counts": {"completed": 34, "total": 110, "pending": 76},
            }
        ]
        block = "\n".join(self.mod.outran_wait_lines(runs, "https://tc.example"))
        self.assertIn("[!WARNING]", block)
        self.assertIn("ran longer than the 5h 45m this run waited", block)
        self.assertIn("Nothing was cancelled", block)
        self.assertIn("34/110 completed, 76 still running", block)
        self.assertIn(f"https://tc.example/tasks/groups/{GROUP}", block)

    def test_a_run_that_finished_in_time_says_nothing(self):
        runs = [{"pool": "win11-64-24h2-hw-alpha", "task_group_id": GROUP}]
        self.assertEqual(self.mod.outran_wait_lines(runs, "https://tc.example"), [])


class TestResultsTable(unittest.TestCase):
    """One table for every pool's tasks, worst first, without the boilerplate
    each pool already fixes."""

    REF = "win11-64-24h2-hw-ref-alpha"
    PERF = "win11-64-24h2-hw-perf-debug"

    @classmethod
    def setUpClass(cls):
        cls.mod = _load_runner()

    def _task(self, pool, platform, suite, state, worker, seconds=60):
        started = datetime.datetime(2026, 8, 21, 18, 0, 0, tzinfo=datetime.timezone.utc)
        resolved = started + datetime.timedelta(seconds=seconds)
        return {
            "status": {
                "taskId": f"{suite[:22]:x<22}",
                "state": state,
                "runs": [
                    {
                        "runId": 0,
                        "workerId": worker,
                        "started": started.isoformat().replace("+00:00", "Z"),
                        "resolved": resolved.isoformat().replace("+00:00", "Z"),
                    }
                ],
            },
            "task": {
                "metadata": {"name": f"gecko-hw-{pool}-test-{platform}/opt-{suite}"}
            },
        }

    def _runs(self):
        return [
            {
                "pool": self.REF,
                "task_group_id": GROUP,
                "identity": {"image": "i", "src_branch": "b", "revision": "r"},
                "verdict": "✅ passed",
                "tasks": [
                    self._task(
                        self.REF,
                        "windows11-64-24h2-hw-ref-shippable",
                        "mochitest-media-mda-gpu",
                        "completed",
                        "t-nuc12-003",
                        seconds=1664,
                    ),
                    self._task(
                        self.REF,
                        "windows11-64-24h2-hw-ref-shippable",
                        "browsertime-benchmark-firefox-speedometer3",
                        "completed",
                        "t-nuc12-002",
                        seconds=815,
                    ),
                ],
            },
            {
                "pool": self.PERF,
                "task_group_id": "PERFGROUPID1234567890",
                "identity": {"image": "i", "src_branch": "b", "revision": "r"},
                "verdict": "❌ failed",
                "tasks": [
                    self._task(
                        self.PERF,
                        "windows11-64-24h2-shippable",
                        "talos-other",
                        "failed",
                        "nuc13-074",
                        seconds=1502,
                    )
                ],
            },
        ]

    def _rendered(self, runs=None):
        with tempfile.NamedTemporaryFile("r+", suffix=".md") as handle:
            os.environ["GITHUB_STEP_SUMMARY"] = handle.name
            try:
                self.mod.write_github_summary(
                    runs or self._runs(), "https://tc.example"
                )
            finally:
                del os.environ["GITHUB_STEP_SUMMARY"]
            return Path(handle.name).read_text()

    def test_every_pool_shares_one_table(self):
        written = self._rendered()
        self.assertEqual(written.count("### Results"), 1)
        # ...and the pool headings the per-pool tables used are gone with them.
        self.assertNotIn(f"### {self.REF}", written)
        self.assertNotIn(f"### {self.PERF}", written)

    def test_a_task_row_drops_what_its_pool_already_says(self):
        row = next(
            line
            for line in self._rendered().splitlines()
            if "mochitest-media-mda-gpu" in line
        )
        self.assertIn("| [mochitest-media-mda-gpu](", row)
        self.assertIn("| ref-alpha |", row)
        self.assertNotIn("gecko-hw-", row)
        self.assertNotIn("hw-ref-shippable", row)

    def test_the_failure_is_the_first_row(self):
        lines = self._rendered().splitlines()
        start = lines.index("|:---:|---|---|---|---:|")
        self.assertIn("talos-other", lines[start + 1])
        # Then longest-running first among the green ones, across both pools.
        self.assertIn("mochitest-media-mda-gpu", lines[start + 2])
        self.assertIn("speedometer3", lines[start + 3])

    def test_the_state_column_is_gone_but_a_strange_state_is_not(self):
        written = self._rendered()
        self.assertNotIn("| Status | Task | Worker | State | Duration |", written)
        self.assertNotIn("| completed |", written)

        runs = self._runs()
        runs[1]["tasks"][0]["status"]["state"] = "wedged"
        row = next(
            line for line in self._rendered(runs).splitlines() if "talos-other" in line
        )
        self.assertIn("talos-other (wedged)", row)
        self.assertIn("❓", row)

    def test_the_platform_is_reported_once_per_pool(self):
        written = self._rendered()
        self.assertIn("| `windows11-64-24h2-hw-ref-shippable/opt` |", written)
        self.assertIn("| `windows11-64-24h2-shippable/opt` |", written)
        # The distinction that matters is ref against non-ref, and it is stated
        # once rather than on all three task rows.
        self.assertEqual(written.count("windows11-64-24h2-hw-ref-shippable"), 1)

    def test_results_sit_between_the_verdict_and_the_deployment(self):
        runs = self._runs()
        runs[0]["deployment"] = {"image": "win11-24h2-hw-20260820-235936"}
        written = self._rendered(runs)
        self.assertLess(written.index("| Pool | Image |"), written.index("### Results"))
        self.assertLess(written.index("### Results"), written.index("### Pool deployment"))

    def test_an_unresolved_task_has_no_duration_and_sorts_above_green(self):
        runs = self._runs()
        pending = self._task(
            self.REF, "windows11-64-24h2-hw-ref-shippable", "xpcshell", "pending", None
        )
        pending["status"]["runs"] = []
        runs[0]["tasks"].append(pending)
        lines = self._rendered(runs).splitlines()
        start = lines.index("|:---:|---|---|---|---:|")
        self.assertIn("talos-other", lines[start + 1])
        self.assertIn("xpcshell", lines[start + 2])
        self.assertTrue(lines[start + 2].endswith("| - |"))
        self.assertIn("`unknown`", lines[start + 2])

    def test_a_name_that_does_not_fit_the_pattern_survives_whole(self):
        # perftest tasks carry no `/opt-`, and a pool name may carry no `-hw-`.
        self.assertEqual(
            self.mod.short_task("gecko-hw-pool-a-perftest-ml-perf-wasm", "pool-a"),
            "perftest-ml-perf-wasm",
        )
        self.assertEqual(self.mod.short_pool("some-other-pool"), "some-other-pool")
        self.assertEqual(self.mod.task_platform([], self.REF), "-")

    def test_a_debug_build_keeps_its_suite_name(self):
        self.assertEqual(
            self.mod.short_task(
                f"gecko-hw-{self.REF}-test-windows11-64-24h2/debug-xpcshell", self.REF
            ),
            "xpcshell",
        )

    def test_no_tasks_means_no_table(self):
        runs = self._runs()
        for run in runs:
            run["tasks"] = []
        self.assertEqual(self.mod.results_table_lines(runs, "https://tc.example"), [])


if __name__ == "__main__":
    unittest.main()
