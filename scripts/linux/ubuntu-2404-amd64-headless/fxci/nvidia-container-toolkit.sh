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

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
  && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt-get update
## Install nvidia-container-toolkit
apt-get install -y nvidia-container-toolkit
## Configure docker to use nvidia container runtime
nvidia-ctk runtime configure --runtime=docker

# For https://github.com/mozilla/translations/issues/1117
# This will create /dev/char symlinks to all device nodes
# See Workarounds section in https://github.com/NVIDIA/nvidia-container-toolkit/issues/48
echo 'ACTION=="add", DEVPATH=="/bus/pci/drivers/nvidia", RUN+="/usr/bin/nvidia-ctk system create-dev-char-symlinks --create-all"' >> /etc/udev/rules.d/71-nvidia-dev-char.rules

## Restart docker daemon to take effect
systemctl restart docker
## export the docker daemon config
cat /etc/docker/daemon.json
