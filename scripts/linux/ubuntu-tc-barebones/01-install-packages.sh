#!/bin/bash

set -exv

# init helpers
function retry {
  set +e
  local n=0
  local max=5
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

retry apt-get update
retry apt-get upgrade -y

# docker wants these
retry apt-get install -y \
  apt-transport-https \
  build-essential \
  ca-certificates \
  curl \
  gnupg-agent \
  python3 \
  python3-pip \
  software-properties-common \
  vim 

MISC_PACKAGES=()
MISC_PACKAGES+=(zstd python3-pip jq)
# docker-worker needs this for unpacking lz4 images
MISC_PACKAGES+=(liblz4-tool)

# misc
retry apt-get install -y ${MISC_PACKAGES[@]}

# Remove apport because it prevents obtaining crashes from containers
# and because it may send data to Canonical.
apt-get purge -y apport
