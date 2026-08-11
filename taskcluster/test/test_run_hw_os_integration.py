# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

"""Tests for ci/run-hw-os-integration.py.

Loaded by path, as the script itself loads hw_pools, because `ci/` is not a
package and the script's own dependencies (taskcluster, requests) are only
installed where it runs.
"""

import importlib.util
import sys
import types
import unittest
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

    def test_node_that_ran_nothing_still_gets_a_row(self):
        runs = self._scored(
            [("nuc13-024", 25.0)], nodes=["nuc13-024", "nuc13-059", "nuc13-119"]
        )
        table = "\n".join(self.mod.worker_summary_lines(runs))
        for node in ("nuc13-024", "nuc13-059", "nuc13-119"):
            self.assertIn(f"`{node}`", table)
        self.assertEqual(
            self.mod.silent_nodes(
                runs[0], runs[0]["scores"]["speedometer3"]["samples"]
            ),
            ["nuc13-059", "nuc13-119"],
        )

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


if __name__ == "__main__":
    unittest.main()
