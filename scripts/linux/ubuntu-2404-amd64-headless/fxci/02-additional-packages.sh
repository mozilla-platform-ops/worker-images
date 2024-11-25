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

# add additional packages

MISC_PACKAGES=()
# essentials
MISC_PACKAGES+=(build-essential curl git gnupg-agent jq mercurial)
# python things
MISC_PACKAGES+=(python3-pip python3-certifi python3-psutil)
# zstd packages
MISC_PACKAGES+=(zstd python3-zstd)
# install zstandard to avoid installing via pip and breaking via PEP 668 https://peps.python.org/pep-0668/ 
MISC_PACKAGES+=(python3-zstandard)
MISC_PACKAGES+=(apt-transport-https ca-certificates software-properties-common)
# docker-worker needs this for unpacking lz4 images, perhaps uneeded but shouldn't hurt
MISC_PACKAGES+=(liblz4-tool)
# random bits
MISC_PACKAGES+=(libhunspell-1.7-0 libhunspell-dev)
# extra things that firefox translations needs
MISC_PACKAGES+=(parallel tmux htop vim nano screen)
# nvidia driver needs this per 
MISC_PACKAGES+=(gcc make dkms pciutils linux-image-gcp linux-headers-gcp)

# install the packages
retry apt-get install -y ${MISC_PACKAGES[@]}
# UV
retry curl -LsSf https://astral.sh/uv/install.sh | sh