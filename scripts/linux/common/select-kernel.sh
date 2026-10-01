#!/bin/bash

set -euxo pipefail

# APT can still be busy during the first boot of the build VM.
retry() {
  local attempt
  for attempt in 1 2 3 4 5; do
    if "$@"; then
      return 0
    fi
    if [ "$attempt" -lt 5 ]; then
      sleep 30
    fi
  done
  return 1
}

# RELOPS-2608: use the same kernel ABI as the September 3 images.
# Keep other kernels installed, but select this kernel on every boot.
: "${KERNEL_VERSION:?KERNEL_VERSION must name the required kernel ABI}"
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
retry apt-get update
retry apt-get -o DPkg::Lock::Timeout=300 install -y "linux-image-${KERNEL_VERSION}" \
  "linux-headers-${KERNEL_VERSION}" "linux-modules-extra-${KERNEL_VERSION}"

mkdir -p /etc/default/grub.d
cat > /etc/default/grub.d/99-worker-images-kernel.cfg <<EOF
GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux ${KERNEL_VERSION}"
GRUB_DISABLE_SUBMENU=false
EOF
update-grub
grep -F "submenu 'Advanced options for Ubuntu'" /boot/grub/grub.cfg
grep -F "menuentry 'Ubuntu, with Linux ${KERNEL_VERSION}'" /boot/grub/grub.cfg
