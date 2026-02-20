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

export DEBIAN_FRONTEND=noninteractive

# Install podman from Ubuntu repos
retry apt-get update
retry apt-get install -y podman

# Workers do not use podman auto-update. Disable it to avoid boot-time churn.
systemctl disable --now podman-auto-update.timer || true

# Configure podman registries to use docker.io by default
mkdir -p /etc/containers
cat > /etc/containers/registries.conf << 'EOF'
[registries.search]
registries=["docker.io"]
EOF

# Verify installation
podman --version
