#!/bin/bash

set -exv

# init helpers
function retry {
  set +e
  local n=0
  local max=10
  while true; do
    "$@" && break || {
      if [[ $n -lt $max ]]; then
        ((n++))
        echo "Command failed" >&2
        sleep_time=$((2 ** n))
        echo "Sleeping $sleep_time seconds..." >&2
        sleep $sleep_time
        echo "Attempt $n/$max:" >&2
      else
        echo "Failed after $n attempts." >&2
        exit 1
      fi
    }
  done
  set -e
}

export DEBIAN_FRONTEND=noninteractive

kernel_version=$(uname -r)
header_package="linux-headers-$kernel_version"

retry apt-get update
retry apt-get -y reinstall linux-headers-gcp $header_package