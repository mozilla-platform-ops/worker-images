#!/bin/bash
set -euo pipefail

# Ubuntu's signed GCP kernel modules avoid compiling NVIDIA DKMS on a GPU-less VM.
# Keep kernel modules and userspace on the same driver branch.
apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any update
apt-get -o Acquire::Retries=10 install -y --no-install-recommends \
  linux-modules-nvidia-580-gcp nvidia-driver-580

# Tasks need the CUDA 12 runtime, not cuDNN headers, samples or static libraries.
repo=cudnn-local-repo-ubuntu2404-9.10.1_1.0-1_amd64.deb
curl -fsSL --retry 10 --retry-all-errors \
  "https://developer.download.nvidia.com/compute/cudnn/9.10.1/local_installers/$repo" -o "/tmp/$repo"
dpkg -i "/tmp/$repo"
rm "/tmp/$repo"
cp /var/cudnn-local-repo-ubuntu2404-9.10.1/cudnn-*-keyring.gpg /usr/share/keyrings/
apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any update
apt-get -o Acquire::Retries=10 install -y --no-install-recommends libcudnn9-cuda-12
