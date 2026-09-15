#!/bin/bash

set -exv

export DEBIAN_FRONTEND=noninteractive

# Install podman from Ubuntu repos
apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any update
apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any install -y podman

# Configure podman registries to use docker.io by default
mkdir -p /etc/containers
cat > /etc/containers/registries.conf << 'EOF'
[registries.search]
registries=["docker.io"]
EOF

# Verify installation
podman --version
