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


def entry(values, version="156.0a1"):
    return {
        "version": version,
        "lower_is_better": False,
        "samples": [{"value": value} for value in values],
    }


class TestProductionScoreComparison(unittest.TestCase):
    def _rows(self, staging, production):
        runs = [
            {
                "pool": "win11-64-24h2-hw-alpha",
                "stages": "win11-64-24h2-hw",
                "scores": {"firefox speedometer3": entry(staging)},
                "production_scores": {"firefox speedometer3": entry(production)},
            }
        ]
        return score_summary.comparisons(runs, summarize)

    def test_close_repeated_scores_are_close(self):
        row = self._rows([25.0, 25.1, 24.9], [24.5, 24.6, 24.4])[0]
        self.assertEqual(row["status"], "close")
        self.assertAlmostEqual(row["delta_percent"], 100 * 0.5 / 24.5)

    def test_material_gap_is_different(self):
        row = self._rows([21.0, 21.1, 20.9], [25.0, 25.1, 24.9])[0]
        self.assertEqual(row["status"], "different")
        self.assertTrue(row["staging_slower"])

    def test_one_sample_is_inconclusive(self):
        row = self._rows([25.0], [25.0])[0]
        self.assertEqual(row["status"], "inconclusive")
        self.assertIn("fewer than", row["reason"])

    def test_noisy_scores_are_inconclusive(self):
        row = self._rows([20.0, 30.0], [24.9, 25.1])[0]
        self.assertEqual(row["status"], "inconclusive")
        self.assertIn("CV", row["reason"])

    def test_raw_table_explains_a_material_slowdown_without_ai(self):
        row = self._rows([21.0, 21.1, 20.9], [25.0, 25.1, 24.9])[0]
        rendered = "\n".join(score_summary.summary_lines([row]))
        self.assertIn("firefox speedometer3 ↑", rendered)
        self.assertIn("staging slower", rendered)


if __name__ == "__main__":
    unittest.main()
