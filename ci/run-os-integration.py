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
"""

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

import requests
import taskcluster


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
        if len(name) > 60:
            name = name[:57] + "..."

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
        lines.append(f"| {emoji} | [`{task_id}`]({task_url}) | {name} | {state} | {duration} |")

    lines.append("")

    summary_path = Path(summary_file)
    with summary_path.open("a") as f:
        f.write("\n".join(lines))


def get_created_task_group_id(queue, decision_task_id: str) -> str | None:
    """
    The decision task creates a new task group for integration tests.
    We need to parse the log to find the taskGroupId of the created tasks.
    """
    for attempt in range(30):
        try:
            # First wait for the decision task to complete
            status = queue.status(decision_task_id)
            state = status["status"]["state"]

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
                    print(f"Decision task failed", file=sys.stderr)
                    return None
                if state == "exception":
                    print(f"Decision task had an exception", file=sys.stderr)
                    return None

            print(f"Attempt {attempt + 1}/30: Decision task state: {state}")
            time.sleep(10)

        except taskcluster.exceptions.TaskclusterRestFailure as e:
            print(f"Attempt {attempt + 1}/30: Waiting for decision task... ({e})")
            time.sleep(10)

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
        default=3600,
        help="Timeout in seconds (default: 3600, i.e. 60 minutes)",
    )
    args = parser.parse_args()

    # Set default root URL if not provided
    if "TASKCLUSTER_ROOT_URL" not in os.environ:
        os.environ["TASKCLUSTER_ROOT_URL"] = (
            "https://firefox-ci-tc.services.mozilla.com"
        )

    # Validate credentials
    if not os.environ.get("TASKCLUSTER_CLIENT_ID"):
        print("Error: TASKCLUSTER_CLIENT_ID is not set", file=sys.stderr)
        sys.exit(1)
    if not os.environ.get("TASKCLUSTER_ACCESS_TOKEN"):
        print("Error: TASKCLUSTER_ACCESS_TOKEN is not set", file=sys.stderr)
        sys.exit(1)

    options = taskcluster.optionsFromEnvironment()
    hooks = taskcluster.Hooks(options)
    queue = taskcluster.Queue(options)

    # Trigger the hook
    print(f"Triggering integration tests for image: {args.image_name}")
    payload = {"images": [args.image_name]}
    print(f"Hook payload: {json.dumps(payload)}")

    response = hooks.triggerHook(
        "project-releng",
        "cron-task-mozilla-platform-ops-worker-images/run-integration-tests",
        payload,
    )

    decision_task_id = response["taskId"]
    root_url = os.environ["TASKCLUSTER_ROOT_URL"].rstrip("/")
    decision_task_url = f"{root_url}/tasks/{decision_task_id}"

    print(f"\nDecision Task ID: {decision_task_id}")
    print(f"Decision Task URL: {decision_task_url}")

    if args.no_wait:
        print("\n--no-wait specified, exiting")
        return

    # Wait for decision task to complete and get the created task group ID
    print("\nWaiting for decision task to complete and create task group...")
    task_group_id = get_created_task_group_id(queue, decision_task_id)

    if not task_group_id:
        print("Failed to get task group ID from decision task", file=sys.stderr)
        print(f"Check decision task: {decision_task_url}", file=sys.stderr)
        sys.exit(1)

    test_results_url = f"{root_url}/tasks/groups/{task_group_id}"

    print(f"\n{'=' * 60}")
    print(f"Integration Task Group ID: {task_group_id}")
    print(f"Integration Test Results:  {test_results_url}")
    print(f"{'=' * 60}\n")

    # Monitor task group (default behavior)
    print("Monitoring task group for completion...")
    start_time = time.time()

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

            print(
                f"Status: {completed}/{total} completed, "
                f"{failed} failed, {exception} exception, "
                f"{pending_running} pending/running"
            )

            if pending_running == 0:
                print()
                print(f"{'=' * 60}")
                print(f"Integration Task Group ID: {task_group_id}")
                print(f"Integration Test Results:  {test_results_url}")
                print(f"{'=' * 60}")

                # Write GitHub Actions job summary
                write_github_summary(tasks, task_group_id, args.image_name, root_url)

                if failed > 0 or exception > 0:
                    print(f"FAILED: {failed} failed, {exception} exception")
                    sys.exit(1)
                else:
                    print(f"PASSED: All {completed} tasks completed successfully")
                    sys.exit(0)

        except taskcluster.exceptions.TaskclusterRestFailure as e:
            print(f"Error checking task group: {e}")

        time.sleep(10)

    # Timeout - still write summary with current state
    try:
        response = queue.listTaskGroup(task_group_id)
        tasks = response.get("tasks", [])
        write_github_summary(tasks, task_group_id, args.image_name, root_url)
    except Exception:
        pass

    print(f"Timeout after {args.timeout} seconds")
    print(f"Task group may still be running: {test_results_url}")
    sys.exit(1)


if __name__ == "__main__":
    main()
