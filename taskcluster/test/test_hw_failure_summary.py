# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

"""Tests for ci/hw_failure_summary.py.

Loaded by path like the runner it belongs to. No test here reaches the API: the
client is faked, so what is pinned is the request this repo sends and what it
does with every answer -- including the answers that are not a summary.
"""

import importlib.util
import json
import os
import sys
import types
import unittest
import unittest.mock
from pathlib import Path

MODULE = Path(__file__).resolve().parent.parent.parent / "ci" / "hw_failure_summary.py"

GROUP = "DECISIONGROUPID1234567"


def _load_module():
    requests_module = types.ModuleType("requests")
    requests_module.RequestException = Exception
    sys.modules.setdefault("requests", requests_module)

    spec = importlib.util.spec_from_file_location("hw_failure_summary", MODULE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _task(name, state, worker="nuc13-074", task_id="a" * 22):
    return {
        "status": {"taskId": task_id, "state": state, "runs": [{"workerId": worker}]},
        "task": {"metadata": {"name": name}},
    }


def _replicated(tasks, group):
    """Stand-in for the runner's helper: everything but the decision task."""
    return [t for t in tasks if t["status"]["taskId"] != group]


class FailureSummaryTestBase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = _load_module()

    def setUp(self):
        self.warnings = []

    def warn(self, message):
        self.warnings.append(message)


class TestFailureCollection(FailureSummaryTestBase):
    def test_only_failed_and_exception_tasks_are_collected(self):
        runs = [
            {
                "pool": "win11-64-24h2-hw-perf-debug",
                "task_group_id": GROUP,
                "tasks": [
                    _task("passed-task", "completed", task_id="b" * 22),
                    _task("failed-task", "failed", task_id="c" * 22),
                    _task("excepted-task", "exception", task_id="d" * 22),
                    _task("still-running", "running", task_id="e" * 22),
                ],
            }
        ]
        failures = self.mod.failing_tasks(runs, _replicated)
        self.assertEqual(
            [f["name"] for f in failures], ["failed-task", "excepted-task"]
        )
        self.assertEqual(failures[0]["pool"], "win11-64-24h2-hw-perf-debug")
        self.assertEqual(failures[0]["worker"], "nuc13-074")

    def test_a_green_run_collects_nothing(self):
        runs = [
            {"pool": "p", "task_group_id": GROUP, "tasks": [_task("t", "completed")]}
        ]
        self.assertEqual(self.mod.failing_tasks(runs, _replicated), [])


class TestLogExcerpt(FailureSummaryTestBase):
    """A log can be megabytes; what goes in the prompt is the part that says
    why it failed."""

    def test_error_lines_are_pulled_out_of_a_long_log(self):
        log = "\n".join(
            ["ordinary progress line"] * 5000
            + ["TEST-UNEXPECTED-FAIL | test_hw_video_decoding.html | expected GPU"]
            + ["more ordinary output"] * 500
        )
        excerpt = self.mod._log_excerpt(log)
        self.assertIn("TEST-UNEXPECTED-FAIL", excerpt)
        self.assertLess(len(excerpt), len(log) / 10, "the excerpt must be a fraction")

    def test_repeated_error_lines_are_quoted_once(self):
        log = "\n".join(["Download failed: HTTP Error 410: Gone"] * 40)
        excerpt = self.mod._log_excerpt(log)
        matched = excerpt.split("log head:")[0]
        self.assertEqual(matched.count("HTTP Error 410"), 1)

    def test_the_verdict_line_survives_a_log_that_keeps_talking(self):
        """Shaped like the ref-alpha mochitest log on 2026-08-19: the line that
        named the defect landed 20 minutes before the end, behind thousands of
        incidental `error` lines. A flat last-N-matches rule dropped it."""
        decisive = (
            "TEST-UNEXPECTED-FAIL | test_hw_video_decoding.html | Playback running "
            "by decoder 'ffvpx video decoder (RDD remote)', expected 'wmf VP9 "
            "codec hardware video decoder'"
        )
        log = "\n".join(
            ["ordinary output"] * 2000
            + [decisive]
            + [
                f"INFO - GECKO | EmptyDatabaseError: not synced yet ({i})"
                for i in range(3000)
            ]
            + ["ordinary output"] * 100
        )
        excerpt = self.mod._log_excerpt(log)
        self.assertIn("wmf VP9 codec hardware video decoder", excerpt)

    def test_one_pathological_log_cannot_decide_the_bill(self):
        log = "\n".join(
            f"TEST-UNEXPECTED-FAIL | {'x' * 5000} | {i}" for i in range(400)
        )
        excerpt = self.mod._log_excerpt(log)
        self.assertLessEqual(len(excerpt), self.mod.MAX_EXCERPT_CHARS + 40)

    def test_a_flood_of_failures_keeps_the_first_and_the_last(self):
        log = "\n".join(f"TEST-UNEXPECTED-FAIL | case_{i}.html" for i in range(400))
        excerpt = self.mod._log_excerpt(log)
        self.assertIn("case_0.html", excerpt)
        self.assertIn("case_399.html", excerpt)
        self.assertIn("similar line(s) omitted", excerpt)

    def test_both_ends_of_the_log_are_kept(self):
        log = "FIRST-LINE\n" + ("filler\n" * 20000) + "LAST-LINE"
        excerpt = self.mod._log_excerpt(log)
        self.assertIn("FIRST-LINE", excerpt)
        self.assertIn("LAST-LINE", excerpt)


class TestPrompt(FailureSummaryTestBase):
    def _runs(self):
        return [
            {
                "pool": "win11-64-24h2-hw-ref-alpha",
                "task_group_id": GROUP,
                "deployment": {
                    "image": "win11-24h2-hw-20260811-202701",
                    "src_branch": "wim-bake-role",
                    "revision": "48a8b9d4",
                },
                "deployment_source": "nuc-wim-pipeline",
            }
        ]

    def test_the_prompt_carries_the_configuration_under_test(self):
        failures = [
            {
                "pool": "win11-64-24h2-hw-ref-alpha",
                "task_id": "x" * 22,
                "name": "mochitest-media-mda-gpu",
                "state": "failed",
                "worker": "t-nuc12-002",
                "excerpt": "TEST-UNEXPECTED-FAIL | expected 'wmf VP9'",
            }
        ]
        prompt = self.mod.build_prompt(self._runs(), failures, [])
        # without the image and ronin pin it cannot tell an image regression
        # from anything else
        self.assertIn("win11-24h2-hw-20260811-202701", prompt)
        self.assertIn("wim-bake-role", prompt)
        self.assertIn("configuration read from nuc-wim-pipeline", prompt)
        self.assertIn("mochitest-media-mda-gpu", prompt)
        self.assertIn("TEST-UNEXPECTED-FAIL", prompt)

    def test_a_repeat_run_quotes_a_sample_and_counts_the_rest(self):
        failures = [
            {
                "pool": "p",
                "task_id": f"{i:022d}",
                "name": f"custom-car-speedometer3-run{i}",
                "state": "failed",
                "worker": "nuc13-074",
                "excerpt": "HTTP Error 410: Gone",
            }
            for i in range(20)
        ]
        prompt = self.mod.build_prompt(self._runs(), failures, [])
        self.assertIn("20 task(s) failed", prompt)
        self.assertIn(f"{20 - self.mod.MAX_TASKS_QUOTED} more failed", prompt)
        self.assertEqual(prompt.count("### task:"), self.mod.MAX_TASKS_QUOTED)

    def test_drift_is_offered_as_a_possible_cause(self):
        drift = [
            {
                "pool": "win11-64-24h2-hw-ref-alpha",
                "field": "image",
                "before": "old-image",
                "after": "new-image",
            }
        ]
        prompt = self.mod.build_prompt(self._runs(), [], drift)
        self.assertIn("changed while the run was in flight", prompt)
        self.assertIn("old-image", prompt)


class _FakeResponse:
    def __init__(self, payload, stop_reason="end_turn"):
        self.stop_reason = stop_reason
        self.content = [types.SimpleNamespace(type="text", text=json.dumps(payload))]
        self.usage = types.SimpleNamespace(input_tokens=2400, output_tokens=180)


class _FakeAnthropic(types.ModuleType):
    """The SDK surface this module actually uses."""

    def __init__(self, response=None, error=None):
        super().__init__("anthropic")
        self.calls = []
        self._response = response
        self._error = error
        module = self

        class Anthropic:
            def __init__(self, **kwargs):
                module.calls.append({"client_kwargs": kwargs})
                self.messages = module._Messages(module)

        self.Anthropic = Anthropic

    class _Messages:
        def __init__(self, module):
            self._module = module

        def create(self, **kwargs):
            self._module.calls.append({"request": kwargs})
            if self._module._error:
                raise self._module._error
            return self._module._response


ANSWER = {
    "verdict": "The baked image is not doing hardware video decode.",
    "failures": [
        {
            "task": "mochitest-media-mda-gpu",
            "category": "image",
            "cause": "Playback fell back to ffvpx software decoding.",
            "evidence": "expected 'wmf VP9 codec hardware video decoder'",
        }
    ],
}


class TestSummarize(FailureSummaryTestBase):
    def _with_sdk(self, fake):
        patcher = unittest.mock.patch.dict(sys.modules, {"anthropic": fake})
        patcher.start()
        self.addCleanup(patcher.stop)
        env = unittest.mock.patch.dict(os.environ, {"ANTHROPIC_API_KEY": "sk-test"})
        env.start()
        self.addCleanup(env.stop)
        return fake

    def test_no_key_means_no_call(self):
        fake = self._with_sdk(_FakeAnthropic(_FakeResponse(ANSWER)))
        with unittest.mock.patch.dict(os.environ, {"ANTHROPIC_API_KEY": ""}):
            self.assertIsNone(self.mod.summarize("prompt", self.warn))
        self.assertEqual(fake.calls, [], "no key, no request, no cost")

    def test_the_request_asks_for_the_schema_it_renders(self):
        fake = self._with_sdk(_FakeAnthropic(_FakeResponse(ANSWER)))
        result = self.mod.summarize("prompt", self.warn)
        request = next(c["request"] for c in fake.calls if "request" in c)
        self.assertEqual(request["model"], self.mod.MODEL)
        fmt = request["output_config"]["format"]
        self.assertEqual(fmt["type"], "json_schema")
        # the table is rendered from these, so the model must be made to send them
        item = fmt["schema"]["properties"]["failures"]["items"]
        self.assertEqual(
            sorted(item["required"]), ["category", "cause", "evidence", "task"]
        )
        self.assertFalse(item["additionalProperties"])
        self.assertEqual(result["failures"][0]["category"], "image")

    def test_a_refusal_is_not_a_summary(self):
        self._with_sdk(_FakeAnthropic(_FakeResponse(ANSWER, stop_reason="refusal")))
        self.assertIsNone(self.mod.summarize("prompt", self.warn))
        self.assertIn("declined", " ".join(self.warnings))

    def test_a_truncated_answer_is_not_a_summary(self):
        self._with_sdk(_FakeAnthropic(_FakeResponse(ANSWER, stop_reason="max_tokens")))
        self.assertIsNone(self.mod.summarize("prompt", self.warn))
        self.assertIn("truncated", " ".join(self.warnings))

    def test_an_api_error_costs_one_line_not_the_run(self):
        self._with_sdk(_FakeAnthropic(error=RuntimeError("connection reset")))
        self.assertIsNone(self.mod.summarize("prompt", self.warn))
        self.assertIn("connection reset", " ".join(self.warnings))

    def test_an_unparseable_answer_costs_one_line(self):
        fake = _FakeAnthropic(_FakeResponse(ANSWER))
        fake._response.content = [types.SimpleNamespace(type="text", text="not json")]
        self._with_sdk(fake)
        self.assertIsNone(self.mod.summarize("prompt", self.warn))
        self.assertIn("could not read the response", " ".join(self.warnings))


RENDER_FAILURES = [
    {
        "pool": "win11-64-24h2-hw-ref-alpha",
        "task_id": "NHzpDLzbTAWBkHxhoo-EnA",
        "name": "mochitest-media-mda-gpu",
        "state": "failed",
        "worker": "t-nuc12-002",
    }
]


class TestRendering(FailureSummaryTestBase):
    FAILURES = RENDER_FAILURES

    def test_the_block_labels_the_category_and_links_the_task(self):
        block = "\n".join(
            self.mod.summary_lines(
                {**ANSWER, "usage": {"input_tokens": 2400, "output_tokens": 180}},
                "https://tc.example",
                self.FAILURES,
            )
        )
        self.assertIn("### Why it failed", block)
        self.assertIn("hardware video decode", block)
        self.assertIn("🖼️ image", block)
        self.assertIn("https://tc.example/tasks/NHzpDLzbTAWBkHxhoo-EnA", block)
        self.assertIn("wmf VP9 codec hardware video decoder", block)
        # the reader has to know a model wrote it and what it read
        self.assertIn(self.mod.MODEL, block)

    def test_nothing_to_say_means_no_block(self):
        self.assertEqual(self.mod.summary_lines(None, "https://tc.example", []), [])
        self.assertEqual(
            self.mod.summary_lines({"verdict": "x", "failures": []}, "u", []), []
        )

    def test_an_unknown_category_is_labelled_rather_than_dropped(self):
        answer = {
            "verdict": "Unclear.",
            "failures": [
                {
                    "task": "mochitest-media-mda-gpu",
                    "category": "something-else",
                    "cause": "The log does not say.",
                    "evidence": "",
                }
            ],
        }
        block = "\n".join(
            self.mod.summary_lines(answer, "https://tc.example", self.FAILURES)
        )
        self.assertIn("❓ unclear", block)
        self.assertNotIn("<details>", block, "no evidence, no evidence section")


if __name__ == "__main__":
    unittest.main()
