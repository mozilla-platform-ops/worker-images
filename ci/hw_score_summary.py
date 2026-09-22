#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

"""Compare repeated staging and production scores, then ask Claude to explain."""

import json
import os

MODEL = "claude-opus-5"
MAX_TOKENS = 4000
API_TIMEOUT_SECONDS = 180

# ponytail: fixed Speedometer guardrails; make these workflow inputs only if
# different hardware families prove they need different tolerances.
CLOSE_PERCENT = 5.0
MAX_CV_PERCENT = 5.0
MIN_SAMPLES = 2

SCHEMA = {
    "type": "object",
    "properties": {
        "verdict": {"type": "string"},
        "findings": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "pool": {"type": "string"},
                    "suite": {"type": "string"},
                    "reading": {"type": "string"},
                },
                "required": ["pool", "suite", "reading"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["verdict", "findings"],
    "additionalProperties": False,
}

SYSTEM = """\
You explain a Firefox Speedometer comparison between a candidate staging pool \
and its production hardware counterpart. The measurements and deterministic \
status are already computed. Do not recalculate, override, or invent numbers. \
Explain whether the scores are close, materially different, or inconclusive, \
and mention noise, sample count, and whether staging is slower when relevant. \
Be concise. A status of inconclusive must never be described as close."""


def comparisons(runs: list[dict], summarize) -> list[dict]:
    """Pair staging and production suites and classify their measured gap."""
    found = []
    for run in runs:
        staging = run.get("scores") or {}
        production = run.get("production_scores") or {}
        for suite in sorted(staging.keys() | production.keys()):
            ours, theirs = staging.get(suite), production.get(suite)
            row = {
                "pool": run["pool"],
                "production_pool": run.get("stages") or "-",
                "suite": suite,
                "status": "inconclusive",
            }
            if not ours or not theirs:
                row["reason"] = "missing staging or production scores"
                found.append(row)
                continue

            ours_stats = summarize([sample["value"] for sample in ours["samples"]])
            their_stats = summarize(
                [sample["value"] for sample in theirs["samples"]]
            )
            mean = their_stats["mean"]
            delta = 100 * (ours_stats["mean"] - mean) / mean if mean else None
            row.update(
                {
                    "staging": ours_stats,
                    "production": their_stats,
                    "delta_percent": delta,
                    "lower_is_better": ours["lower_is_better"],
                    "staging_slower": (
                        delta < 0 if not ours["lower_is_better"] else delta > 0
                    )
                    if delta is not None
                    else None,
                }
            )
            if ours.get("version") != theirs.get("version"):
                row["reason"] = "browser versions differ"
            elif min(ours_stats["n"], their_stats["n"]) < MIN_SAMPLES:
                row["reason"] = f"fewer than {MIN_SAMPLES} samples"
            elif max(ours_stats["cv"], their_stats["cv"]) > MAX_CV_PERCENT:
                row["reason"] = f"run-to-run CV exceeds {MAX_CV_PERCENT:.0f}%"
            elif delta is None:
                row["reason"] = "production mean is zero"
            elif abs(delta) <= CLOSE_PERCENT:
                row["status"] = "close"
            else:
                row["status"] = "different"
            found.append(row)
    return found


def _ask(rows: list[dict], warn) -> dict | None:
    if not rows or not os.environ.get("ANTHROPIC_API_KEY"):
        return None
    try:
        import anthropic

        response = anthropic.Anthropic(timeout=API_TIMEOUT_SECONDS).messages.create(
            model=MODEL,
            max_tokens=MAX_TOKENS,
            system=SYSTEM,
            output_config={
                "effort": "medium",
                "format": {"type": "json_schema", "schema": SCHEMA},
            },
            messages=[
                {
                    "role": "user",
                    "content": "Explain these computed comparisons:\n"
                    + json.dumps(rows, sort_keys=True),
                }
            ],
        )
        if response.stop_reason in ("refusal", "max_tokens"):
            raise ValueError(f"response ended with {response.stop_reason}")
        text = next(
            (block.text for block in response.content if block.type == "text"), ""
        )
        result = json.loads(text)
        result["usage"] = {
            "input_tokens": response.usage.input_tokens,
            "output_tokens": response.usage.output_tokens,
        }
        return result
    except Exception as exc:  # noqa: BLE001 -- AI commentary is never fatal
        warn(f"no score comparison summary: {type(exc).__name__}: {exc}")
        return None


def summary_lines(rows: list[dict], ai: dict | None = None) -> list[str]:
    if not rows:
        return []
    lines = [
        "### Production comparison",
        "",
        (
            f"Close means the two means are within {CLOSE_PERCENT:.0f}%, with at "
            f"least {MIN_SAMPLES} scores each and CV no higher than "
            f"{MAX_CV_PERCENT:.0f}%."
        ),
        "",
        "| Staging | Production | Suite | Runs | Means | Difference | CV | Result |",
        "|---|---|---|:---:|---:|---:|---:|---|",
    ]
    for row in rows:
        ours, theirs = row.get("staging"), row.get("production")
        if not ours or not theirs:
            runs = means = delta = cv = "-"
        else:
            runs = f"{ours['n']} / {theirs['n']}"
            means = f"{ours['mean']:.2f} / {theirs['mean']:.2f}"
            delta = (
                f"{row['delta_percent']:+.1f}%"
                if row.get("delta_percent") is not None
                else "-"
            )
            cv = f"{ours['cv']:.1f}% / {theirs['cv']:.1f}%"
        mark = {"close": "✅ close", "different": "⚠️ different"}.get(
            row["status"], "❔ inconclusive"
        )
        if row["status"] == "different":
            mark += " — staging " + (
                "slower" if row.get("staging_slower") else "faster"
            )
        reason = f" — {row['reason']}" if row.get("reason") else ""
        direction = "↓" if row.get("lower_is_better") else "↑"
        lines.append(
            f"| `{row['pool']}` | `{row['production_pool']}` | "
            f"{row['suite']} {direction} | "
            f"{runs} | {means} | {delta} | {cv} | {mark}{reason} |"
        )

    if ai:
        lines += ["", "#### AI reading", "", ai.get("verdict", "").strip(), ""]
        lines += [
            f"- **{item['pool']} · {item['suite']}**: {item['reading']}"
            for item in ai.get("findings") or []
        ]
        usage = ai.get("usage") or {}
        lines += [
            "",
            (
                f"> Written by {MODEL} from the computed table above "
                f"({usage.get('input_tokens', '?')} in, "
                f"{usage.get('output_tokens', '?')} out). The table, not the AI "
                "wording, is authoritative."
            ),
        ]
    lines.append("")
    return lines


def build(runs: list[dict], summarize, warn) -> list[str]:
    rows = comparisons(runs, summarize)
    return summary_lines(rows, _ask(rows, warn))
