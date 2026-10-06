"""Offline checks for the alpha failure-summary job."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "ci"))
import alpha_failure_summary as alpha


class AlphaFailureSummaryTests(unittest.TestCase):
    def test_collect_build_and_paginated_integration_failures(self):
        jobs = [
            {"id": 1, "name": "Build test-image", "conclusion": "failure", "html_url": "https://github.com/build"},
            {"id": 2, "name": "OS Integration Tests - test-image / Trigger Integration Tests", "conclusion": "failure", "html_url": "https://github.com/test"},
            {"id": 3, "name": "Build passing-image", "conclusion": "success"},
        ]
        queue = Mock()
        queue.listTaskGroup.side_effect = [
            {"tasks": [], "continuationToken": "next"},
            {"tasks": [{"status": {"taskId": "task", "state": "exception", "runs": [{"workerId": "vm"}]},
                        "task": {"metadata": {"name": "webgl"}}}]},
        ]
        queue.getLatestArtifact.return_value = "TEST-UNEXPECTED-FAIL missing GPU"
        _, failures = alpha.collect(jobs, lambda job: "Pester failed" if job == 1 else alpha.ROOT + "/tasks/groups/group", queue, self.fail)
        self.assertEqual([f["name"] for f in failures], [jobs[0]["name"], jobs[1]["name"], "webgl"])
        self.assertIn("missing GPU", failures[-1]["excerpt"])
        queue.listTaskGroup.assert_called_with("group", {"continuationToken": "next"})
        rendered = alpha.summary.summary_lines({"failures": [{"task": jobs[0]["name"], "category": "test", "cause": "wrong cache path"}]}, alpha.ROOT, failures)
        self.assertIn("https://github.com/build", "\n".join(rendered))

    def test_missing_logs_keeps_failure_link(self):
        job = {"id": 1, "name": "Build test-image", "conclusion": "failure", "html_url": "https://github.com/build"}
        _, failures = alpha.collect([job], Mock(side_effect=RuntimeError("unavailable")), Mock(), Mock())
        self.assertEqual(failures[0]["url"], job["html_url"])

    def test_current_attempt_and_ai_failure_preserve_plain_summary(self):
        job = {"id": 1, "name": "Build test-image", "conclusion": "failure", "html_url": "https://github.com/build"}
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "summary.md"
            env = {"GITHUB_STEP_SUMMARY": str(output), "GITHUB_REPOSITORY": "org/repo", "GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "2"}
            with patch.dict(os.environ, env), patch.object(alpha, "gh", side_effect=[json.dumps([{"jobs": [job]}]), "Pester failure"]) as gh, patch.object(alpha.summary, "summarize", side_effect=RuntimeError("timeout")) as summarize:
                alpha.main()
                summarize.assert_called_once()
            self.assertIn("/attempts/2/jobs", gh.call_args_list[0].args[0])
            self.assertIn("https://github.com/build", output.read_text())
            self.assertIn("summary unavailable", output.read_text())

    def test_cloud_prompt_keeps_classification_rules(self):
        self.assertIn("Azure alpha image run", alpha.SYSTEM)
        self.assertNotIn("candidate WIM", alpha.SYSTEM)
        self.assertIn("untrusted evidence", alpha.SYSTEM)


if __name__ == "__main__":
    unittest.main()
