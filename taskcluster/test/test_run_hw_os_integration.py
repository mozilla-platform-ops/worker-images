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


def _task(task_id, state, name=None):
    return {
        "status": {"taskId": task_id, "state": state},
        "task": {"metadata": {"name": name or task_id}},
    }


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

    def _run_with(self, blobs, states=None):
        """`blobs` maps task id -> perfherder blob, or None for no artifact."""
        states = states or {}

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
                "tasks": [_task(GROUP, "completed")]
                + [
                    _task(task_id, states.get(task_id, "completed"))
                    for task_id in blobs
                ],
            }
        ]
        self.mod.collect_scores(Queue(), runs)
        return runs

    def test_one_value_per_completed_task(self):
        runs = self._run_with(
            {
                "run1": _perfherder(24.5, [24.3, 24.6]),
                "run2": _perfherder(25.5, [25.4, 25.6]),
                "run3": _perfherder(23.5),
            }
        )
        entry = runs[0]["scores"]["speedometer3"]
        self.assertEqual(sorted(entry["values"]), [23.5, 24.5, 25.5])
        self.assertEqual(entry["unit"], "score")
        self.assertFalse(entry["lower_is_better"])
        self.assertEqual(len(entry["replicates"]), 4)

    def test_failed_tasks_and_tasks_without_data_contribute_nothing(self):
        runs = self._run_with(
            {
                "run1": _perfherder(24.5),
                "noperf": None,
                "broken": _perfherder(99.9),
            },
            states={"broken": "failed"},
        )
        self.assertEqual(runs[0]["scores"]["speedometer3"]["values"], [24.5])

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
        self.assertIn("per run: 24.50, 25.50", table)


if __name__ == "__main__":
    unittest.main()
