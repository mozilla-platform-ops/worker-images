#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "taskcluster",
#     "requests",
# ]
# ///
"""
Run OS integration tests by triggering the Taskcluster hook.

Usage:
    uv run ci/run-os-integration.py <image_name>
    uv run ci/run-os-integration.py <image_name> --no-wait

Example:
    uv run ci/run-os-integration.py win11_64_24h2_alpha
    uv run ci/run-os-integration.py win11_64_24h2_alpha --no-wait

Environment variables (required):
    TASKCLUSTER_CLIENT_ID      - Taskcluster client ID
    TASKCLUSTER_ACCESS_TOKEN   - Taskcluster access token

Optional:
    TASKCLUSTER_ROOT_URL       - Defaults to https://firefox-ci-tc.services.mozilla.com
    GITHUB_STEP_SUMMARY        - GitHub Actions step summary file (auto-detected)

Polling behavior:
    Decision task polling: every 10 seconds
    Task group polling: every 5 minutes
    Task group status log output: every 10 minutes
"""

import argparse
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import requests
import taskcluster

IN_GITHUB_ACTIONS = os.environ.get("GITHUB_ACTIONS") == "true"
DECISION_TASK_POLL_INTERVAL_SECONDS = 10
TASK_GROUP_POLL_INTERVAL_SECONDS = 300
TASK_GROUP_LOG_INTERVAL_SECONDS = 600


def _escape_github_command_message(message: str) -> str:
    return message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def log_message(level: str, message: str, include_datetimestamp: bool = False) -> None:
    if include_datetimestamp:
        timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        message = f"[{timestamp}] {message}"

    if IN_GITHUB_ACTIONS:
        escaped_message = _escape_github_command_message(message)
        print(f"::{level}::{escaped_message}")
        return

    if level == "error":
        print(f"ERROR: {message}", file=sys.stderr)
    elif level == "warning":
        print(f"WARNING: {message}")
    else:
        print(message)


def log_notice(message: str, include_datetimestamp: bool = False) -> None:
    log_message("notice", message, include_datetimestamp)


def log_warning(message: str, include_datetimestamp: bool = False) -> None:
    log_message("warning", message, include_datetimestamp)


def log_error(message: str, include_datetimestamp: bool = False) -> None:
    log_message("error", message, include_datetimestamp)


def format_duration(seconds: int) -> str:
    """Format duration in seconds as human-readable string."""
    if seconds < 0:
        return "-"
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        minutes = seconds // 60
        secs = seconds % 60
        return f"{minutes}m {secs}s"
    hours = seconds // 3600
    minutes = (seconds % 3600) // 60
    return f"{hours}h {minutes}m"


def get_result_emoji(state: str, result: str | None) -> str:
    """Get emoji for task result."""
    if state in ("pending", "running", "unscheduled"):
        return "\u23f3"  # hourglass
    if state == "completed":
        return "\u2705"  # green check
    if state == "failed":
        return "\u274c"  # red x
    if state == "exception":
        return "\u26a0\ufe0f"  # warning
    return "\u2753"  # question mark


def write_github_summary(
    tasks: list[dict],
    task_group_id: str,
    image_name: str,
    root_url: str,
) -> None:
    """Write a job summary for GitHub Actions."""
    summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_file:
        return

    task_group_url = f"{root_url}/tasks/groups/{task_group_id}"

    # Calculate summary stats
    states = [t["status"]["state"] for t in tasks]
    completed = sum(1 for s in states if s == "completed")
    failed = sum(1 for s in states if s == "failed")
    exception = sum(1 for s in states if s == "exception")
    pending_running = sum(1 for s in states if s in ("pending", "running", "unscheduled"))
    total = len(tasks)

    # Determine overall status
    if pending_running > 0:
        overall_status = "\u23f3 In Progress"
    elif failed > 0 or exception > 0:
        overall_status = "\u274c Failed"
    else:
        overall_status = "\u2705 Passed"

    lines = [
        f"## OS Integration Tests - {image_name}",
        "",
        f"**Status:** {overall_status}",
        f"**Task Group:** [{task_group_id}]({task_group_url})",
        "",
        f"| Completed | Failed | Exception | Pending/Running | Total |",
        f"|:---------:|:------:|:---------:|:---------------:|:-----:|",
        f"| {completed} | {failed} | {exception} | {pending_running} | {total} |",
        "",
        "### Task Details",
        "",
        "| Status | Task ID | Name | State | Duration |",
        "|:------:|---------|------|-------|----------|",
    ]

    for task in tasks:
        task_id = task["status"]["taskId"]
        task_url = f"{root_url}/tasks/{task_id}"
        state = task["status"]["state"]

        # Get task name from task definition
        name = task.get("task", {}).get("metadata", {}).get("name", "Unknown")

        # Calculate duration from runs
        duration = "-"
        runs = task["status"].get("runs", [])
        if runs:
            last_run = runs[-1]
            started = last_run.get("started")
            resolved = last_run.get("resolved")
            if started and resolved:
                from datetime import datetime

                start_dt = datetime.fromisoformat(started.replace("Z", "+00:00"))
                end_dt = datetime.fromisoformat(resolved.replace("Z", "+00:00"))
                duration = format_duration(int((end_dt - start_dt).total_seconds()))

        emoji = get_result_emoji(state, None)
        lines.append(f"| {emoji} | [{task_id}]({task_url}) | {name} | {state} | {duration} |")

    lines.append("")

    summary_path = Path(summary_file)
    with summary_path.open("a") as f:
        f.write("\n".join(lines))


def get_created_task_group_id(
    queue,
    decision_task_id: str,
    include_datetimestamp: bool = False,
) -> str | None:
    """
    The decision task creates a new task group for integration tests.
    We need to parse the log to find the taskGroupId of the created tasks.
    """
    last_state = None
    last_error = None

    for _ in range(30):
        try:
            # First wait for the decision task to complete
            status = queue.status(decision_task_id)
            state = status["status"]["state"]

            if state != last_state:
                log_notice(
                    f"Decision task state changed: {state}",
                    include_datetimestamp,
                )
                last_state = state

            if state in ("completed", "failed", "exception"):
                # Get the log artifact
                artifact = queue.getLatestArtifact(
                    decision_task_id, "public/logs/live_backing.log"
                )
                if isinstance(artifact, dict) and "url" in artifact:
                    resp = requests.get(artifact["url"], timeout=30)
                    log_content = resp.text

                    # Find taskGroupId in the log (the one created by the decision task)
                    # Look for the JSON output which contains the created taskGroupId
                    matches = re.findall(
                        r'"taskGroupId":\s*"([A-Za-z0-9_-]{22})"', log_content
                    )
                    if matches:
                        # The first match that differs from the decision task's own group
                        for match in matches:
                            if match != decision_task_id:
                                return match
                        # If all matches are the same, return the first one
                        return matches[0]

                if state == "failed":
                    log_error("Decision task failed", include_datetimestamp)
                    return None
                if state == "exception":
                    log_error(
                        "Decision task had an exception",
                        include_datetimestamp,
                    )
                    return None

            time.sleep(DECISION_TASK_POLL_INTERVAL_SECONDS)

        except taskcluster.exceptions.TaskclusterRestFailure as e:
            error_text = str(e)
            if error_text != last_error:
                log_warning(
                    f"Waiting for decision task artifacts ({error_text})",
                    include_datetimestamp,
                )
                last_error = error_text
            time.sleep(DECISION_TASK_POLL_INTERVAL_SECONDS)

    return None


def main():
    parser = argparse.ArgumentParser(description="Trigger OS integration tests")
    parser.add_argument(
        "image_name", help="Image name to test (e.g., win11_64_24h2_alpha)"
    )
    parser.add_argument(
        "--no-wait",
        action="store_true",
        help="Don't wait for task group URL or completion (exit immediately after triggering)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=7200,
        help="Timeout in seconds (default: 7200, i.e. 2 hours)",
    )
    args = parser.parse_args()
    include_datetimestamp = True

    # Set default root URL if not provided
    if "TASKCLUSTER_ROOT_URL" not in os.environ:
        os.environ["TASKCLUSTER_ROOT_URL"] = (
            "https://firefox-ci-tc.services.mozilla.com"
        )

    # Validate credentials
    if not os.environ.get("TASKCLUSTER_CLIENT_ID"):
        log_error("TASKCLUSTER_CLIENT_ID is not set", include_datetimestamp)
        sys.exit(1)
    if not os.environ.get("TASKCLUSTER_ACCESS_TOKEN"):
        log_error("TASKCLUSTER_ACCESS_TOKEN is not set", include_datetimestamp)
        sys.exit(1)

    options = taskcluster.optionsFromEnvironment()
    hooks = taskcluster.Hooks(options)
    queue = taskcluster.Queue(options)

    # Trigger the hook
    log_notice(
        f"Triggering integration tests for image: {args.image_name}",
        include_datetimestamp,
    )
    payload = {"images": [args.image_name]}
    log_notice(f"Hook payload: {json.dumps(payload)}", include_datetimestamp)

    response = hooks.triggerHook(
        "project-releng",
        "cron-task-mozilla-platform-ops-worker-images/run-integration-tests",
        payload,
    )

    decision_task_id = response["taskId"]
    root_url = os.environ["TASKCLUSTER_ROOT_URL"].rstrip("/")
    decision_task_url = f"{root_url}/tasks/{decision_task_id}"

    log_notice(f"Decision Task ID: {decision_task_id}", include_datetimestamp)
    log_notice(f"Decision Task URL: {decision_task_url}", include_datetimestamp)

    if args.no_wait:
        log_notice("--no-wait specified, exiting", include_datetimestamp)
        return

    # Wait for decision task to complete and get the created task group ID
    log_notice(
        "Waiting for decision task to complete and create task group...",
        include_datetimestamp,
    )
    task_group_id = get_created_task_group_id(
        queue,
        decision_task_id,
        include_datetimestamp=include_datetimestamp,
    )

    if not task_group_id:
        log_error(
            f"Failed to get task group ID from decision task: {decision_task_url}",
            include_datetimestamp,
        )
        sys.exit(1)

    test_results_url = f"{root_url}/tasks/groups/{task_group_id}"

    log_notice(f"Integration Task Group ID: {task_group_id}", include_datetimestamp)
    log_notice(f"Integration Test Results: {test_results_url}", include_datetimestamp)

    # Monitor task group (default behavior)
    log_notice("Monitoring task group for completion...", include_datetimestamp)
    start_time = time.time()
    last_status_log_at: float | None = None
    last_task_group_error = None

    while time.time() - start_time < args.timeout:
        try:
            response = queue.listTaskGroup(task_group_id)
            tasks = response.get("tasks", [])

            states = [t["status"]["state"] for t in tasks]
            pending_running = sum(
                1 for s in states if s in ("pending", "running", "unscheduled")
            )
            completed = sum(1 for s in states if s == "completed")
            failed = sum(1 for s in states if s == "failed")
            exception = sum(1 for s in states if s == "exception")
            total = len(tasks)

            now = time.time()
            if (
                now - start_time >= TASK_GROUP_LOG_INTERVAL_SECONDS
                and (
                    last_status_log_at is None
                    or now - last_status_log_at >= TASK_GROUP_LOG_INTERVAL_SECONDS
                )
            ):
                elapsed = format_duration(int(time.time() - start_time))
                log_notice(
                    f"Status update ({elapsed}): {completed}/{total} completed, "
                    f"{failed} failed, {exception} exception, "
                    f"{pending_running} pending/running",
                    include_datetimestamp,
                )
                last_status_log_at = now
            last_task_group_error = None

            if pending_running == 0:
                log_notice(
                    f"Integration Task Group ID: {task_group_id}",
                    include_datetimestamp,
                )
                log_notice(
                    f"Integration Test Results: {test_results_url}",
                    include_datetimestamp,
                )

                # Write GitHub Actions job summary
                write_github_summary(tasks, task_group_id, args.image_name, root_url)

                if failed > 0 or exception > 0:
                    msg = f"FAILED: {failed} failed, {exception} exception — {test_results_url}"
                    log_error(msg, include_datetimestamp)
                    sys.exit(1)
                else:
                    msg = f"PASSED: All {completed} tasks completed successfully"
                    log_notice(msg, include_datetimestamp)
                    sys.exit(0)

        except taskcluster.exceptions.TaskclusterRestFailure as e:
            error_text = str(e)
            if error_text != last_task_group_error:
                log_warning(
                    f"Error checking task group: {e}",
                    include_datetimestamp,
                )
                last_task_group_error = error_text

        time.sleep(TASK_GROUP_POLL_INTERVAL_SECONDS)

    # Timeout - still write summary with current state
    try:
        response = queue.listTaskGroup(task_group_id)
        tasks = response.get("tasks", [])
        write_github_summary(tasks, task_group_id, args.image_name, root_url)
    except Exception:
        pass

    msg = f"Timeout after {args.timeout}s — task group may still be running: {test_results_url}"
    log_error(msg, include_datetimestamp)
    sys.exit(1)


if __name__ == "__main__":
    main()
