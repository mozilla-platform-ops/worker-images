 # Transform config name: replace - with _
          TRANSFORMED_CONFIG=$(echo "$CONFIG" | sed 's/-/_/g')
          echo "Transformed config: $TRANSFORMED_CONFIG"
          
          # Trigger the hook and capture response
          RESPONSE=$(echo "{\"images\": [\"$TRANSFORMED_CONFIG\"]}" | taskcluster api hooks triggerHook project-releng cron-task-mozilla-platform-ops-worker-images/run-integration-tests)
          echo "Hook response: $RESPONSE"
          
          # Extract taskId from response
          TASK_ID=$(echo "$RESPONSE" | jq -r '.taskId')
          echo "Task ID: $TASK_ID"
          echo "task_id=$TASK_ID" >> $GITHUB_ENV
          
          # Wait for live.log to become available and get the actual log URL
          echo "Waiting for live.log to become available for task $TASK_ID..."
          RETRY_COUNT=0
          MAX_RETRIES=30
          LIVE_LOG_RESPONSE=""
          
          while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
            echo "Attempt $((RETRY_COUNT + 1))/$MAX_RETRIES: Checking for live.log..."
            LIVE_LOG_RESPONSE=$(taskcluster api queue getLatestArtifact "$TASK_ID" public/logs/live.log 2>/dev/null || echo "")
            
            if [ -n "$LIVE_LOG_RESPONSE" ]; then
              echo "Live log response received"
              break
            fi
            
            echo "Live log not ready yet, waiting 10 seconds..."
            sleep 10
            RETRY_COUNT=$((RETRY_COUNT + 1))
          done
          
          if [ -z "$LIVE_LOG_RESPONSE" ]; then
            echo "Failed to get live.log after $MAX_RETRIES attempts"
            exit 1
          fi
          
          # Extract the actual log URL from the JSON response
          LIVE_LOG_URL=$(echo "$LIVE_LOG_RESPONSE" | jq -r '.url')
          echo "Live log URL: $LIVE_LOG_URL"
          
          # Download the actual live_backing.log content
          echo "Downloading live_backing.log content..."
          LIVE_LOG_CONTENT=$(curl -s "$LIVE_LOG_URL")
          
          # Extract taskGroupId from the log content
          TASK_GROUP_ID=$(echo "$LIVE_LOG_CONTENT" | grep -o '"taskGroupId": "[^"]*"' | head -1 | sed 's/"taskGroupId": "\([^"]*\)"/\1/')
          echo "Task Group ID: $TASK_GROUP_ID"
          echo "task_group_id=$TASK_GROUP_ID" >> $GITHUB_ENV
          
          # Generate and display the test results URL
          TEST_RESULTS_URL="https://firefox-ci-tc.services.mozilla.com/tasks/groups/$TASK_GROUP_ID"
          echo "Integration test results available at: $TEST_RESULTS_URL"
          echo "test_results_url=$TEST_RESULTS_URL" >> $GITHUB_ENV
          
          # Wait for all tasks in the task group to complete and check their status
          echo "Monitoring task group $TASK_GROUP_ID for completion..."
          MONITOR_RETRY_COUNT=0
          MAX_MONITOR_RETRIES=120  # 20 minutes max wait time
          ALL_COMPLETED=false
          
          while [ $MONITOR_RETRY_COUNT -lt $MAX_MONITOR_RETRIES ] && [ "$ALL_COMPLETED" = "false" ]; do
            echo "Checking task group status (attempt $((MONITOR_RETRY_COUNT + 1))/$MAX_MONITOR_RETRIES)..."
            
            # Get all tasks in the task group
            TASK_GROUP_RESPONSE=$(taskcluster api queue listTaskGroup "$TASK_GROUP_ID" 2>/dev/null || echo "")
            
            if [ -z "$TASK_GROUP_RESPONSE" ]; then
              echo "Failed to get task group info, retrying in 10 seconds..."
              sleep 10
              MONITOR_RETRY_COUNT=$((MONITOR_RETRY_COUNT + 1))
              continue
            fi
            
            # Parse task statuses
            TASK_STATES=$(echo "$TASK_GROUP_RESPONSE" | jq -r '.tasks[].status.state')
            PENDING_OR_RUNNING=$(echo "$TASK_STATES" | grep -E "pending|running" | wc -l)
            COMPLETED_TASKS=$(echo "$TASK_STATES" | grep "completed" | wc -l)
            FAILED_TASKS=$(echo "$TASK_STATES" | grep "failed" | wc -l)
            EXCEPTION_TASKS=$(echo "$TASK_STATES" | grep "exception" | wc -l)
            TOTAL_TASKS=$(echo "$TASK_STATES" | wc -l)
            
            echo "Task status summary:"
            echo "  Total tasks: $TOTAL_TASKS"
            echo "  Completed: $COMPLETED_TASKS"
            echo "  Failed: $FAILED_TASKS"
            echo "  Exception: $EXCEPTION_TASKS"
            echo "  Pending/Running: $PENDING_OR_RUNNING"
            
            # Check if all tasks are complete (no pending or running)
            if [ "$PENDING_OR_RUNNING" -eq 0 ]; then
              ALL_COMPLETED=true
              echo "All tasks in task group have completed!"
              
              # Check for any failures
              if [ "$FAILED_TASKS" -gt 0 ] || [ "$EXCEPTION_TASKS" -gt 0 ]; then
                echo "❌ Integration tests FAILED!"
                echo "  Failed tasks: $FAILED_TASKS"
                echo "  Exception tasks: $EXCEPTION_TASKS"
                echo "  Check the task group for details: $TEST_RESULTS_URL"
                exit 1
              else
                echo "✅ All integration tests PASSED!"
                echo "  All $COMPLETED_TASKS tasks completed successfully"
              fi
            else
              echo "Tasks still running/pending, waiting 10 seconds..."
              sleep 10
              MONITOR_RETRY_COUNT=$((MONITOR_RETRY_COUNT + 1))
            fi
          done
          
          if [ "$ALL_COMPLETED" = "false" ]; then
            echo "⚠️  Timeout waiting for task group to complete after $((MAX_MONITOR_RETRIES * 10 / 60)) minutes"
            echo "Task group may still be running: $TEST_RESULTS_URL"
            exit 1
          fi