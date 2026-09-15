# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.

"""Ask Claude why a hardware run's tasks failed, and say so in the summary.

Two red runs can mean opposite things. On 2026-08-19 the perf-debug run failed
because a Chrome-canary fetch artifact had expired hours earlier, and the
ref-alpha run failed because the baked WIM fell back to software video decode
where production hardware uses WMF -- one is a stale index, the other is the
regression this workflow exists to catch. Both read `❌ failed`, and a reader
who has been trained by the first stops looking at the second.

So the failing tasks' logs, and the configuration they ran on, go to the model
with one question: for each failure, is this the image, the infrastructure, the
test, or this harness -- and what is the evidence. The answer is rendered from a
schema rather than pasted as prose, so the summary's shape does not depend on
what came back.

Never fatal, and never on the critical path: the verdict, the scores and the
task-group links are already in the summary before this runs. A missing key, a
refusal, a timeout or a bad response costs one line saying so.
"""

import json
import os

import requests

MODEL = "claude-opus-5"
MAX_TOKENS = 16000
# Classification against evidence that is already in front of it -- the reading
# is the work, not the reasoning. Medium keeps a red run's summary prompt.
EFFORT = "medium"
API_TIMEOUT_SECONDS = 180

LOG_ARTIFACT = "public/logs/live_backing.log"

# Enough of a log to hold the failure and what led to it, small enough that a
# pool-wide failure is still one cheap call. Both ends matter: harness errors
# land at the tail, test failures partway up.
LOG_TAIL_CHARS = 6000
LOG_HEAD_CHARS = 1500
# A repeat run fails the same way N times; the model needs the shape, not every
# copy. Anything past this is counted in the prompt but not quoted.
MAX_TASKS_QUOTED = 8

# Matched case-insensitively: the line that mattered on 2026-08-19 was
# "Download failed: HTTP Error 410: Gone", which a case-sensitive `ERROR` or
# `FAIL` would have walked straight past.
#
# Two tiers, because a mochitest log carries thousands of incidental `error`
# lines -- console noise, benign service warnings -- and a flat "keep the last
# N matches" rule pushes the verdict out of the excerpt. The ref-alpha run on
# 2026-08-19 failed on `expected 'wmf VP9 codec hardware video decoder'` at
# 23:51 and then logged noise until 00:15; the line that named the defect was
# the one that got dropped.
PRIMARY = (
    "test-unexpected",
    "traceback",
    "fatal",
    "result: failed",
    "no such file",
    "permission denied",
    "exit status",
    "exit code",
    "timed out",
)
SECONDARY = ("error", "fail", "exception")

# Primary lines are the verdict, so keep a wide window and take it from both
# ends -- the first failure and the last are both worth having.
MAX_PRIMARY = 50
MAX_SECONDARY = 20
# A ceiling per task so one pathological log cannot decide the bill: eight of
# these is the worst case a red run can send.
MAX_EXCERPT_CHARS = 24000

CATEGORIES = ("image", "infrastructure", "test", "harness", "unknown")

CATEGORY_LABEL = {
    "image": "🖼️ image",
    "infrastructure": "🔧 infrastructure",
    "test": "🧪 test",
    "harness": "⚙️ harness",
    "unknown": "❓ unclear",
}

SCHEMA = {
    "type": "object",
    "properties": {
        "verdict": {
            "type": "string",
            "description": (
                "One sentence a reader can act on: what failed and whether it "
                "says anything about the image under test."
            ),
        },
        "failures": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "task": {
                        "type": "string",
                        "description": "The task name exactly as given.",
                    },
                    "category": {"type": "string", "enum": list(CATEGORIES)},
                    "cause": {
                        "type": "string",
                        "description": "One sentence naming the cause.",
                    },
                    "evidence": {
                        "type": "string",
                        "description": (
                            "The single log line that shows it, quoted from the "
                            "excerpt. Empty if the excerpt does not contain one."
                        ),
                    },
                },
                "required": ["task", "category", "cause", "evidence"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["verdict", "failures"],
    "additionalProperties": False,
}

SYSTEM = """\
You are reading logs from a Firefox CI hardware integration run. The run boots \
Windows test machines from a candidate WIM image and a ronin_puppet \
configuration, then replicates mozilla-central's own test tasks onto them. Its \
question is always the same: is the image good?

For each failing task, decide which of these it is, and say what the evidence is:

- image: the machine is not configured the way it should be. Missing or wrong \
drivers, absent codecs, wrong software versions, a capability present on \
production hardware and absent here. This is the finding the run exists for.
- infrastructure: the failure is upstream of the machine. Expired or missing \
fetch artifacts, HTTP errors retrieving dependencies, Taskcluster problems, \
network failures. Says nothing about the image.
- test: the test itself failed on its own terms -- a real product bug, or a \
known-intermittent test being intermittent.
- harness: this workflow or its replication got something wrong -- a bad scope, \
a malformed task, a dependency that could never resolve.
- unknown: the excerpt does not support a conclusion. Say so rather than guessing.

Quote evidence verbatim from the excerpt given to you. Do not invent log lines. \
Keep each cause to one sentence; the reader is scanning, and the full log is one \
click away. When several tasks failed the same way, say so plainly in each \
rather than cross-referencing."""


def _dedupe(lines: list[str]) -> list[str]:
    """A retry loop says the same thing ten times; quote it once."""
    seen, unique = set(), []
    for line in lines:
        key = line.strip()[-200:]
        if key not in seen:
            seen.add(key)
            unique.append(line)
    return unique


def _window(lines: list[str], limit: int) -> list[str]:
    """Both ends of an over-long list, rather than only the tail."""
    if len(lines) <= limit:
        return lines
    half = limit // 2
    return [
        *lines[:half],
        f"... {len(lines) - limit} similar line(s) omitted ...",
        *lines[-half:],
    ]


def _log_excerpt(text: str) -> str:
    """The part of a log worth paying for: the failure lines, plus both ends."""
    lines = text.splitlines()
    primary, secondary = [], []
    for line in lines:
        lowered = line.lower()
        if any(marker in lowered for marker in PRIMARY):
            primary.append(line)
        elif any(marker in lowered for marker in SECONDARY):
            secondary.append(line)

    parts = []
    if primary:
        parts.append(
            "failure lines:\n" + "\n".join(_window(_dedupe(primary), MAX_PRIMARY))
        )
    if secondary:
        parts.append(
            "other error lines:\n" + "\n".join(_dedupe(secondary)[-MAX_SECONDARY:])
        )

    parts.append(f"log head:\n{text[:LOG_HEAD_CHARS]}")
    parts.append(f"log tail:\n{text[-LOG_TAIL_CHARS:]}")

    excerpt = "\n\n".join(parts)
    if len(excerpt) > MAX_EXCERPT_CHARS:
        # Keep the failure lines, which lead: a log pathological enough to
        # reach here has a wall of them, and the tail is the least of it.
        excerpt = excerpt[:MAX_EXCERPT_CHARS] + "\n... excerpt truncated ..."
    return excerpt


def fetch_log(queue, task_id: str, warn) -> str | None:
    """A task's log, or None. Same artifact shape as the perfherder blob."""
    try:
        response = queue.getLatestArtifact(task_id, LOG_ARTIFACT)
    except Exception as exc:  # noqa: BLE001 -- a missing log is not a failure
        warn(f"  could not read the log of {task_id}: {exc}")
        return None

    if isinstance(response, dict) and "url" in response:
        try:
            http = requests.get(response["url"], timeout=60)
            http.raise_for_status()
            return http.text
        except requests.RequestException as exc:
            warn(f"  could not read the log of {task_id}: {exc}")
            return None
    if isinstance(response, (bytes, bytearray)):
        return response.decode("utf-8", "replace")
    return response if isinstance(response, str) else None


def failing_tasks(runs: list[dict], replicated) -> list[dict]:
    """Every task a reader would want explained, newest failure state first."""
    failing = []
    for run in runs:
        for task in replicated(run.get("tasks") or [], run.get("task_group_id")):
            status = task.get("status", {})
            if status.get("state") not in ("failed", "exception"):
                continue
            runs_ = status.get("runs") or []
            failing.append(
                {
                    "pool": run["pool"],
                    "task_id": status.get("taskId"),
                    "name": task.get("task", {}).get("metadata", {}).get("name", "?"),
                    "state": status.get("state"),
                    "worker": (runs_[-1].get("workerId") if runs_ else None) or "?",
                }
            )
    return failing


def _pool_context(runs: list[dict]) -> str:
    """What each pool was running, so the model can reason about the image."""
    lines = []
    for run in runs:
        deployment = run.get("deployment") or {}
        if not deployment:
            continue
        fields = ", ".join(
            f"{key}={value}"
            for key, value in deployment.items()
            if value not in (None, "")
        )
        source = run.get("deployment_source")
        origin = f" (configuration read from {source})" if source else ""
        lines.append(f"- {run['pool']}: {fields}{origin}")
    return "\n".join(lines) or "- (no deployment details were resolved)"


def build_prompt(runs: list[dict], failures: list[dict], drift: list[dict]) -> str:
    quoted = failures[:MAX_TASKS_QUOTED]
    dropped = len(failures) - len(quoted)

    sections = [
        "Pools under test and the configuration each was running:",
        _pool_context(runs),
        "",
        f"{len(failures)} task(s) failed. "
        + (
            f"The first {len(quoted)} are quoted below; {dropped} more failed and "
            "are not quoted."
            if dropped
            else "All are quoted below."
        ),
    ]

    if drift:
        sections += [
            "",
            (
                "The configuration changed while the run was in flight, which "
                "may itself explain a failure:"
            ),
            "\n".join(
                f"- {change.get('pool')}: {change.get('field')} "
                f"{change.get('before')!r} -> {change.get('after')!r}"
                for change in drift[:10]
            ),
        ]

    for failure in quoted:
        sections += [
            "",
            f"### task: {failure['name']}",
            (
                f"pool={failure['pool']} worker={failure['worker']} "
                f"state={failure['state']} taskId={failure['task_id']}"
            ),
            "",
            failure.get("excerpt") or "(no log could be read for this task)",
        ]

    sections += [
        "",
        (
            "For each quoted task, classify the failure and give the evidence. "
            "Then give the one-sentence verdict for the run as a whole."
        ),
    ]
    return "\n".join(sections)


def summarize(prompt: str, warn) -> dict | None:
    """The model's read of the failures, or None with a reason logged."""
    if not os.environ.get("ANTHROPIC_API_KEY"):
        return None

    try:
        import anthropic
    except ImportError as exc:
        warn(f"no failure summary: anthropic is not installed ({exc})")
        return None

    try:
        client = anthropic.Anthropic(timeout=API_TIMEOUT_SECONDS)
        response = client.messages.create(
            model=MODEL,
            max_tokens=MAX_TOKENS,
            system=SYSTEM,
            output_config={
                "effort": EFFORT,
                "format": {"type": "json_schema", "schema": SCHEMA},
            },
            messages=[{"role": "user", "content": prompt}],
        )
    except Exception as exc:  # noqa: BLE001 -- a summary is never worth a failure
        warn(f"no failure summary: {type(exc).__name__}: {exc}")
        return None

    if response.stop_reason == "refusal":
        warn("no failure summary: the request was declined")
        return None
    if response.stop_reason == "max_tokens":
        warn("no failure summary: the response was truncated")
        return None

    text = next((b.text for b in response.content if b.type == "text"), "")
    try:
        parsed = json.loads(text)
    except ValueError as exc:
        warn(f"no failure summary: could not read the response ({exc})")
        return None

    parsed["usage"] = {
        "input_tokens": response.usage.input_tokens,
        "output_tokens": response.usage.output_tokens,
    }
    return parsed


def summary_lines(result: dict | None, root_url: str, failures: list[dict]) -> list:
    """The block itself. Empty when there is nothing trustworthy to say."""
    if not result or not result.get("failures"):
        return []

    by_name = {failure["name"]: failure for failure in failures}
    lines = [
        "### Why it failed",
        "",
        f"{result.get('verdict', '').strip()}",
        "",
        "| Task | Reading | Cause |",
        "|---|---|---|",
    ]
    for item in result["failures"]:
        name = item.get("task", "?")
        failure = by_name.get(name)
        label = CATEGORY_LABEL.get(item.get("category"), CATEGORY_LABEL["unknown"])
        shown = name.split("/opt-")[-1] if "/opt-" in name else name
        if failure and failure.get("task_id"):
            shown = f"[{shown}]({root_url}/tasks/{failure['task_id']})"
        lines.append(f"| {shown} | {label} | {item.get('cause', '').strip()} |")

    evidence = [
        (item.get("task", "?"), item["evidence"].strip())
        for item in result["failures"]
        if item.get("evidence", "").strip()
    ]
    if evidence:
        lines += ["", "<details><summary>Evidence</summary>", ""]
        for name, line in evidence:
            lines += [f"`{name}`", "", "```", line, "```", ""]
        lines.append("</details>")

    usage = result.get("usage") or {}
    lines += [
        "",
        (
            f"> Written by {MODEL} from the failing tasks' logs and each pool's "
            f"configuration ({usage.get('input_tokens', '?')} in, "
            f"{usage.get('output_tokens', '?')} out). It reads logs; it does "
            "not run anything. Check the linked task before acting on it."
        ),
        "",
    ]
    return lines


def build(queue, runs, replicated, drift, root_url, warn) -> tuple[list, list]:
    """Collect, ask, render. Returns (summary lines, failing tasks)."""
    failures = failing_tasks(runs, replicated)
    if not failures:
        return [], []

    for failure in failures[:MAX_TASKS_QUOTED]:
        log = fetch_log(queue, failure["task_id"], warn)
        if log:
            failure["excerpt"] = _log_excerpt(log)

    result = summarize(build_prompt(runs, failures, drift or []), warn)
    return summary_lines(result, root_url, failures), failures
