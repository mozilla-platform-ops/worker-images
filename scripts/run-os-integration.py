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
    uv run scripts/run-os-integration.py <image_name>

Example:
    uv run scripts/run-os-integration.py win11_64_24h2_alpha

Environment variables (required):
    TASKCLUSTER_CLIENT_ID      - Taskcluster client ID
    TASKCLUSTER_ACCESS_TOKEN   - Taskcluster access token

Optional:
    TASKCLUSTER_ROOT_URL       - Defaults to https://firefox-ci-tc.services.mozilla.com
"""

import argparse
import json
import os
import re
import sys
import time

import requests
import taskcluster


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
        "--no-wait", action="store_true", help="Don't wait for task completion"
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
    print(f"Decision Task ID: {decision_task_id}")
    print(f"Decision Task URL: {root_url}/tasks/{decision_task_id}")

    if args.no_wait:
        print("--no-wait specified, exiting")
        return

    # Wait for decision task to complete and get the created task group ID
    print("\nWaiting for decision task to complete and create task group...")
    task_group_id = get_created_task_group_id(queue, decision_task_id)

    if not task_group_id:
        print("Failed to get task group ID from decision task", file=sys.stderr)
        sys.exit(1)

    print(f"Integration Task Group ID: {task_group_id}")
    test_results_url = f"{root_url}/tasks/groups/{task_group_id}"
    print(f"Integration test results: {test_results_url}\n")

    # Monitor task group
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
                if failed > 0 or exception > 0:
                    print(f"FAILED: {failed} failed, {exception} exception")
                    print(f"Details: {test_results_url}")
                    sys.exit(1)
                else:
                    print(f"PASSED: All {completed} tasks completed successfully")
                    sys.exit(0)

        except taskcluster.exceptions.TaskclusterRestFailure as e:
            print(f"Error checking task group: {e}")

        time.sleep(10)

    print(f"Timeout after {args.timeout} seconds")
    print(f"Task group may still be running: {test_results_url}")
    sys.exit(1)


if __name__ == "__main__":
    main()
