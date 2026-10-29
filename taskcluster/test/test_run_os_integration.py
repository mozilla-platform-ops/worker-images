# /// script
# dependencies = ["requests", "taskcluster"]
# ///
"""uv run taskcluster/test/test_run_os_integration.py"""

from pathlib import Path
import runpy
import unittest
from unittest.mock import Mock


script = runpy.run_path(str(Path(__file__).resolve().parents[2] / "ci/run-os-integration.py"))


class ResultsTest(unittest.TestCase):
    def test_reads_all_pages_including_later_failure(self):
        queue = Mock()
        passed = {"status": {"state": "completed"}}
        failed = {"status": {"state": "failed"}}
        queue.listTaskGroup.side_effect = [
            {"tasks": [passed], "continuationToken": "next-page"},
            {"tasks": [failed]},
        ]
        self.assertEqual(script["get_task_group_tasks"](queue, "group"), [passed, failed])
        queue.listTaskGroup.assert_called_with("group", query={"continuationToken": "next-page"})

    def test_empty_group_fails(self):
        queue = Mock()
        queue.listTaskGroup.return_value = {"tasks": []}
        with self.assertRaises(ValueError):
            script["get_task_group_tasks"](queue, "group")

    def test_failed_decision_does_not_accept_partial_group(self):
        queue = Mock()
        queue.status.return_value = {"status": {"state": "failed"}}
        self.assertIsNone(script["get_created_task_group_id"](queue, "decision"))
        queue.getLatestArtifact.assert_not_called()


if __name__ == "__main__":
    unittest.main()
