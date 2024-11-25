#!/bin/bash

set -exv

retry curl -fSsL -O https://github.com/GoogleCloudPlatform/compute-gpu-installation/releases/download/cuda-installer-v1.1.0/cuda_installer.pyz
python3 cuda_installer.pyz install_cuda

python3 cuda_installer.pyz verify_cuda