function Invoke-OSIntegrationTests {
    [CmdletBinding()]
    param (
        [string]$Config,
        [string]$TaskClusterClientId,
        [string]$TaskClusterAccessToken,
        [string]$TaskClusterRootUrl,
        [string]$Taskcluster
    )
    
    ## Is Taskcluster cli locally available?
    & $Taskcluster "version"

    $ENV:TASKCLUSTER_CLIENT_ID = $TaskClusterClientId
    $ENV:TASKCLUSTER_ACCESS_TOKEN = $TaskClusterAccessToken
    $ENV:TASKCLUSTER_ROOT_URL = $TaskClusterRootUrl

    # Transform config name: replace - with _
    $TRANSFORMED_CONFIG = $Config -replace '-', '_'
    Write-Host "Transformed config: $TRANSFORMED_CONFIG"

    # Trigger the hook and capture response
    $hookPayload = @{
        images = @($TRANSFORMED_CONFIG)
    } | ConvertTo-Json -Compress
    Write-Host "Hook payload: $hookPayload"

    $trigger_args = @("api", "hooks", "triggerHook", "project-releng", "cron-task-mozilla-platform-ops-worker-images/run-integration-tests")
    $RESPONSE = $hookPayload | & $Taskcluster @trigger_args
    Write-Host "Hook response: $RESPONSE"

    # Extract taskId from response
    $responseObj = $RESPONSE | ConvertFrom-Json
    $TASK_ID = $responseObj.taskId
    Write-Host "Task ID: $TASK_ID"
    "task_id=$TASK_ID" | Out-File -FilePath $env:GITHUB_ENV -Append

    # Wait for live.log to become available and get the actual log URL
    Write-Host "Waiting for live.log to become available for task $TASK_ID..."
    $RETRY_COUNT = 0
    $MAX_RETRIES = 30
    $LIVE_LOG_RESPONSE = $null

    while ($RETRY_COUNT -lt $MAX_RETRIES) {
        Write-Host "Attempt $($RETRY_COUNT + 1)/$MAX_RETRIES`: Checking for live.log..."
              
        try {
            $live_log_args = @("api", "queue", "getLatestArtifact", $TASK_ID, "public/logs/live.log")
            $LIVE_LOG_RESPONSE = & $Taskcluster @live_log_args 2>$null
            if ($LIVE_LOG_RESPONSE) {
                Write-Host "Live log response received"
                break
            }
        }
        catch {
            Write-Host "Live log not ready yet..."
        }
              
        Write-Host "Live log not ready yet, waiting 10 seconds..."
        Start-Sleep -Seconds 10
        $RETRY_COUNT++
    }

    if (-not $LIVE_LOG_RESPONSE) {
        Write-Host "Failed to get live.log after $MAX_RETRIES attempts"
        exit 1
    }

    # Extract the actual log URL from the JSON response
    $liveLogObj = $LIVE_LOG_RESPONSE | ConvertFrom-Json
    $LIVE_LOG_URL = $liveLogObj.url
    Write-Host "Live log URL: $LIVE_LOG_URL"

    # Download the actual live_backing.log content
    Write-Host "Downloading live_backing.log content..."
    $LIVE_LOG_CONTENT = Invoke-RestMethod -Uri $LIVE_LOG_URL -Method Get

    # Extract taskGroupId from the log content
    $taskGroupMatch = [regex]::Match($LIVE_LOG_CONTENT, '"taskGroupId": "([^"]*)"')
    if ($taskGroupMatch.Success) {
        $TASK_GROUP_ID = $taskGroupMatch.Groups[1].Value
        Write-Host "Task Group ID: $TASK_GROUP_ID"
        "task_group_id=$TASK_GROUP_ID" | Out-File -FilePath $env:GITHUB_ENV -Append
    }
    else {
        Write-Host "Failed to extract taskGroupId from live.log"
        exit 1
    }

    # Generate and display the test results URL
    $TEST_RESULTS_URL = "https://firefox-ci-tc.services.mozilla.com/tasks/groups/$TASK_GROUP_ID"
    Write-Host "Integration test results available at: $TEST_RESULTS_URL"
    "test_results_url=$TEST_RESULTS_URL" | Out-File -FilePath $env:GITHUB_ENV -Append

    # Wait for all tasks in the task group to complete and check their status
    Write-Host "Monitoring task group $TASK_GROUP_ID for completion..."
    $MONITOR_RETRY_COUNT = 0
    $MAX_MONITOR_RETRIES = 120  # 20 minutes max wait time
    $ALL_COMPLETED = $false

    while ($MONITOR_RETRY_COUNT -lt $MAX_MONITOR_RETRIES -and -not $ALL_COMPLETED) {
        Write-Host "Checking task group status (attempt $($MONITOR_RETRY_COUNT + 1)/$MAX_MONITOR_RETRIES)..."
              
        try {
            # Get all tasks in the task group
            $task_group_response_params = @("api", "queue", "listTaskGroup", $TASK_GROUP_ID)
            $TASK_GROUP_RESPONSE = & $Taskcluster @task_group_response_params 2>$null
            if (-not $TASK_GROUP_RESPONSE) {
                Write-Host "Failed to get task group info, retrying in 10 seconds..."
                Start-Sleep -Seconds 10
                $MONITOR_RETRY_COUNT++
                continue
            }
                  
            # Parse task statuses
            $taskGroupObj = $TASK_GROUP_RESPONSE | ConvertFrom-Json
            $taskStates = $taskGroupObj.tasks | ForEach-Object { $_.status.state }
                  
            $PENDING_OR_RUNNING = ($taskStates | Where-Object { $_ -in @('pending', 'running') }).Count
            $COMPLETED_TASKS = ($taskStates | Where-Object { $_ -eq 'completed' }).Count
            $FAILED_TASKS = ($taskStates | Where-Object { $_ -eq 'failed' }).Count
            $EXCEPTION_TASKS = ($taskStates | Where-Object { $_ -eq 'exception' }).Count
            $TOTAL_TASKS = $taskStates.Count
                  
            Write-Host "Task status summary:"
            Write-Host "  Total tasks: $TOTAL_TASKS"
            Write-Host "  Completed: $COMPLETED_TASKS"
            Write-Host "  Failed: $FAILED_TASKS"
            Write-Host "  Exception: $EXCEPTION_TASKS"
            Write-Host "  Pending/Running: $PENDING_OR_RUNNING"
                  
            # Check if all tasks are complete (no pending or running)
            if ($PENDING_OR_RUNNING -eq 0) {
                $ALL_COMPLETED = $true
                Write-Host "All tasks in task group have completed!"
                      
                # Check for any failures
                if ($FAILED_TASKS -gt 0 -or $EXCEPTION_TASKS -gt 0) {
                    Write-Host "❌ Integration tests FAILED!"
                    Write-Host "  Failed tasks: $FAILED_TASKS"
                    Write-Host "  Exception tasks: $EXCEPTION_TASKS"
                    Write-Host "  Check the task group for details: $TEST_RESULTS_URL"
                    exit 1
                }
                else {
                    Write-Host "✅ All integration tests PASSED!"
                    Write-Host "  All $COMPLETED_TASKS tasks completed successfully"
                }
            }
            else {
                Write-Host "Tasks still running/pending, waiting 10 seconds..."
                Start-Sleep -Seconds 10
                $MONITOR_RETRY_COUNT++
            }
        }
        catch {
            Write-Host "Error checking task group status: $($_.Exception.Message)"
            Write-Host "Retrying in 10 seconds..."
            Start-Sleep -Seconds 10
            $MONITOR_RETRY_COUNT++
        }
    }

    if (-not $ALL_COMPLETED) {
        $timeoutMinutes = [math]::Round($MAX_MONITOR_RETRIES * 10 / 60, 1)
        Write-Host "⚠️  Timeout waiting for task group to complete after $timeoutMinutes minutes"
        Write-Host "Task group may still be running: $TEST_RESULTS_URL"
        exit 1
    }
}