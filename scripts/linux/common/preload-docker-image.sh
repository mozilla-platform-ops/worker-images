#!/bin/bash
# Load the Docker image that the latest autoland push uses for PRELOAD_IMAGE_LABEL.
# Docker then skips its layers when a task loads a child image (ubuntu2404-test).
set -euo pipefail

root_url=https://firefox-ci-tc.services.mozilla.com
label="docker-image-${PRELOAD_IMAGE_LABEL:-ubuntu2404-test-base}"

decision=$(curl -fsSL --retry 5 "$root_url/api/index/v1/task/gecko.v2.autoland.latest.taskgraph.decision" | jq -r .taskId)
task_id=$(curl -fsSL --retry 5 "$root_url/api/queue/v1/task/$decision/artifacts/public/label-to-taskid.json" | jq -er --arg l "$label" '.[$l]')

systemctl is-active --quiet docker || systemctl start docker
curl -fsSL --retry 5 -o /tmp/preload-image.tar.zst "$root_url/api/queue/v1/task/$task_id/artifacts/public/image.tar.zst"
docker load -i /tmp/preload-image.tar.zst
rm -f /tmp/preload-image.tar.zst

mkdir -p /etc/worker-images
echo "$label $task_id decision=$decision $(date -u +%FT%TZ)" >> /etc/worker-images/preloaded-docker-images.txt
docker images --digests
