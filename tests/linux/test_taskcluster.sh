#!/bin/bash
set -euo pipefail

: "${TASKCLUSTER_VERSION:?TASKCLUSTER_VERSION must be set}"
actual=$(generic-worker --short-version)
if [[ "$actual" != "$TASKCLUSTER_VERSION" ]]; then
  echo "Expected generic-worker $TASKCLUSTER_VERSION, got $actual" >&2
  exit 1
fi
