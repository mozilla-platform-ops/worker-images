#!/bin/bash

set -exv

curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
  && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any update
## Install nvidia-container-toolkit
apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any install -y nvidia-container-toolkit
command -v nvidia-ctk
nvidia-ctk --version
## Configure docker to use nvidia container runtime
nvidia-ctk runtime configure --runtime=docker
## Restart docker daemon to take effect
systemctl restart docker
## export the docker daemon config
cat /etc/docker/daemon.json
grep -q '"nvidia"' /etc/docker/daemon.json
