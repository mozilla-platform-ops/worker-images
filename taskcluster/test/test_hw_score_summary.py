# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

import importlib.util
import statistics
import unittest
from pathlib import Path

MODULE = Path(__file__).resolve().parents[2] / "ci" / "hw_score_summary.py"
SPEC = importlib.util.spec_from_file_location("hw_score_summary", MODULE)
score_summary = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(score_summary)


def summarize(values):
    mean = statistics.fmean(values)
    stdev = statistics.stdev(values) if len(values) > 1 else 0.0
    return {
        "n": len(values),
        "mean": mean,
        "median": statistics.median(values),
        "min": min(values),
        "max": max(values),
        "stdev": stdev,
        "cv": 100 * stdev / mean if mean else 0.0,
    }


def baseline(flag=False, worse=True):
    return {
        "percent": -10.0 if worse else 8.0,
        "sigmas": 4.0,
        "worse": worse,
        "comparable": True,
        "flag": flag,
        "baseline": {
            "source": "perfherder",
            "detail": "7d of mozilla-central",
            "n": 40,
            "mean": 25.0,
            "median": 25.0,
            "min": 24.0,
            "max": 26.0,
            "stdev": 0.5,
        },
    }


def runs(comparison):
    entry = {
        "lower_is_better": False,
        "samples": [{"value": 22.5}, {"value": 22.5}],
    }
    if comparison:
        entry["baseline"] = comparison
    return [
        {
            "pool": "win11-64-24h2-hw-alpha",
            "scores": {"firefox speedometer3": entry},
        }
    ]


class TestPerfherderScoreSummary(unittest.TestCase):
    def test_flagged_slowdown_is_a_possible_regression(self):
        row = score_summary.comparisons(runs(baseline(flag=True)), summarize)[0]
        self.assertEqual(row["status"], "possible regression")
        self.assertTrue(row["staging_slower"])

    def test_unflagged_slowdown_is_within_production_spread(self):
        row = score_summary.comparisons(runs(baseline()), summarize)[0]
        self.assertEqual(row["status"], "within production spread")

    def test_faster_score_is_named_as_faster(self):
        row = score_summary.comparisons(runs(baseline(worse=False)), summarize)[0]
        self.assertEqual(row["status"], "faster than production")

    def test_equal_score_is_named_as_a_match(self):
        comparison = baseline(worse=False)
        comparison["percent"] = 0.0
        row = score_summary.comparisons(runs(comparison), summarize)[0]
        self.assertEqual(row["status"], "matches production")

    def test_missing_baseline_is_inconclusive(self):
        row = score_summary.comparisons(runs(None), summarize)[0]
        self.assertEqual(row["status"], "inconclusive")
        self.assertIn("unavailable", row["reason"])

    def test_thin_baseline_is_inconclusive(self):
        comparison = baseline()
        comparison["comparable"] = False
        row = score_summary.comparisons(runs(comparison), summarize)[0]
        self.assertEqual(row["status"], "inconclusive")
        self.assertIn("too little data", row["reason"])

    def test_raw_table_is_authoritative_without_ai(self):
        row = score_summary.comparisons(runs(baseline(flag=True)), summarize)[0]
        rendered = "\n".join(score_summary.summary_lines([row]))
        self.assertIn("firefox speedometer3 ↑", rendered)
        self.assertIn("⚠️ possible regression", rendered)
        self.assertIn("25.00 (n=40)", rendered)


if __name__ == "__main__":
    unittest.main()
