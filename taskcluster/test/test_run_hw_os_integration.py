import importlib.util
import unittest
from pathlib import Path
from types import SimpleNamespace


def _load_runner():
    path = Path(__file__).parents[2] / "ci" / "run-hw-os-integration.py"
    spec = importlib.util.spec_from_file_location("run_hw_os_integration", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeQueue:
    def __init__(self, workers=None, tasks=None):
        self.workers = workers or []
        self.tasks = tasks or []

    def listWorkers(self, provisioner_id, worker_type):
        return {"workers": self.workers}

    def taskQueueCounts(self, task_queue_id):
        return {"pendingTasks": 0, "claimedTasks": 0}

    def listTaskGroup(self, task_group_id):
        return {"tasks": self.tasks}


class TestRunHwOsIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runner = _load_runner()

    def test_preflight_rejects_active_worker_outside_expected_pool(self):
        pool = SimpleNamespace(
            name="staging",
            identity={},
            task_queue_id="releng-hardware/staging",
            is_low_capacity=False,
            node_count=1,
            nodes=("expected",),
        )
        registry = SimpleNamespace(
            pools={
                "staging": pool,
                "other": SimpleNamespace(nodes=("foreign",)),
            },
            known_bad_nodes=frozenset(),
            healthy_nodes=lambda name: ("expected",),
        )
        queue = FakeQueue(workers=[{"workerId": "expected"}, {"workerId": "foreign"}])

        report = self.runner.preflight(queue, registry, pool, min_healthy=2)

        self.assertFalse(report["ok"])
        self.assertEqual(report["active"], 1)
        self.assertTrue(
            any("foreign" in problem for problem in report["problems"]),
            report,
        )

    def test_monitor_excludes_decision_task_from_results(self):
        decision_id = "decision-task"
        child_id = "child-task"
        queue = FakeQueue(
            tasks=[
                {"status": {"taskId": decision_id, "state": "completed"}},
                {
                    "status": {
                        "taskId": child_id,
                        "state": "completed",
                        "runs": [{"workerId": "expected"}],
                    }
                },
            ]
        )
        runs = [
            {
                "pool": "staging",
                "decision_task_id": decision_id,
                "task_group_id": decision_id,
            }
        ]

        self.runner.monitor(queue, runs, timeout=1, root_url="https://tc.example")

        self.assertEqual(runs[0]["counts"]["total"], 1)
        self.assertEqual(runs[0]["tasks"][0]["status"]["taskId"], child_id)

    def test_unexpected_workers_reports_non_pool_workers(self):
        tasks = [
            {
                "status": {
                    "state": "completed",
                    "runs": [{"workerId": "expected"}, {"workerId": "foreign"}],
                }
            }
        ]

        self.assertEqual(
            self.runner.unexpected_workers(tasks, {"expected"}), {"foreign"}
        )


if __name__ == "__main__":
    unittest.main()
