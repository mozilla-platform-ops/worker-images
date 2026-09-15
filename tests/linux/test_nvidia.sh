#!/bin/bash
set -euo pipefail

# No GPU is attached to the builder. Check the booted kernel's module and package
# provenance here; real GPU/container/cuDNN execution belongs in OS integration.
[[ $(modinfo -F version nvidia) == 580.* ]]
[[ -n $(modinfo -F signer nvidia) ]]
for package in nvidia-driver-580 libcudnn9-cuda-12; do
  [[ $(dpkg-query -W -f='${Status}' "$package") == 'install ok installed' ]]
done
if dkms status | grep -qi nvidia; then
  echo 'Expected prebuilt NVIDIA kernel modules, found an NVIDIA DKMS build' >&2
  exit 1
fi
nvidia-ctk --version
grep -q '"nvidia"' /etc/docker/daemon.json
