#!/bin/bash

set -exv

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

## Install nvidia driver
retry curl -sSO https://developer.download.nvidia.com/compute/nvidia-driver/565.57.01/local_installers/nvidia-driver-local-repo-ubuntu2404-565.57.01_1.0-1_amd64.deb
dpkg -i nvidia-driver-local-repo-ubuntu2404-565.57.01_1.0-1_amd64.deb
cp /var/nvidia-driver-local-repo-ubuntu2404-565.57.01/nvidia-driver-*-keyring.gpg /usr/share/keyrings/
apt-get update
apt-get install -y cuda-drivers-565

# Install cudnn
retry curl -sSO https://developer.download.nvidia.com/compute/cudnn/9.5.1/local_installers/cudnn-local-repo-ubuntu2404-9.5.1_1.0-1_amd64.deb
dpkg -i cudnn-local-repo-ubuntu2404-9.5.1_1.0-1_amd64.deb
cp /var/cudnn-local-repo-ubuntu2404-9.5.1/cudnn-*-keyring.gpg /usr/share/keyrings/
apt-get update
apt-get -y install cudnn