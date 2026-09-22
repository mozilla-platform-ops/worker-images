#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

"""Ask Claude to explain staging scores against their Perfherder baseline."""

import json
import os

MODEL = "claude-opus-5"
MAX_TOKENS = 4000
API_TIMEOUT_SECONDS = 180

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
You explain Firefox hardware performance scores from a candidate staging pool \
against the computed Perfherder production baseline. The measurements, direction, \
and deterministic status are already computed. Do not recalculate, override, or \
invent numbers. Explain whether staging is consistent with production, faster, a \
possible regression, or inconclusive. Mention sample count and production spread \
when relevant. Be concise. Never describe an unavailable baseline as a pass."""


def comparisons(runs: list[dict], summarize) -> list[dict]:
    """Flatten the runner's measured scores and attached baselines for Claude."""
    rows = []
    for run in runs:
        for suite, entry in sorted((run.get("scores") or {}).items()):
            ours = summarize([sample["value"] for sample in entry["samples"]])
            row = {
                "pool": run["pool"],
                "suite": suite,
                "staging": ours,
                "lower_is_better": entry["lower_is_better"],
                "status": "inconclusive",
            }
            comparison = entry.get("baseline")
            if comparison and comparison.get("comparable"):
                row.update(
                    {
                        "production": comparison["baseline"],
                        "delta_percent": comparison["percent"],
                        "sigmas": comparison["sigmas"],
                        "staging_slower": comparison["worse"],
                        "status": (
                            "possible regression"
                            if comparison["flag"]
                            else "within production spread"
                            if comparison["worse"]
                            else "faster than production"
                        ),
                    }
                )
            else:
                row["reason"] = (
                    "Perfherder baseline has too little data or no spread"
                    if comparison
                    else "Perfherder baseline unavailable"
                )
            rows.append(row)
    return rows


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
        warn(f"no Perfherder comparison summary: {type(exc).__name__}: {exc}")
        return None


def summary_lines(rows: list[dict], ai: dict | None = None) -> list[str]:
    if not rows:
        return []
    lines = [
        "### Perfherder comparison",
        "",
        "| Pool | Suite | Runs | Staging | Production | Difference | Spread | Result |",
        "|---|---|:---:|---:|---:|---:|---:|---|",
    ]
    for row in rows:
        production = row.get("production")
        direction = "↓" if row["lower_is_better"] else "↑"
        if production:
            baseline = f"{production['mean']:.2f} (n={production['n']})"
            delta = f"{row['delta_percent']:+.1f}%"
            spread = (
                f"{row['sigmas']:.1f}σ" if row.get("sigmas") is not None else "-"
            )
        else:
            baseline = delta = spread = "-"
        mark = {
            "possible regression": "⚠️ possible regression",
            "within production spread": "✅ within production spread",
            "faster than production": "✅ faster than production",
        }.get(row["status"], "❔ inconclusive")
        reason = f" — {row['reason']}" if row.get("reason") else ""
        lines.append(
            f"| `{row['pool']}` | {row['suite']} {direction} | "
            f"{row['staging']['n']} | {row['staging']['mean']:.2f} | {baseline} | "
            f"{delta} | {spread} | {mark}{reason} |"
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
