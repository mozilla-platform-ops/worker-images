#!/bin/bash

set -euxo pipefail

# RELOPS-2608: use the same kernel ABI as the September 3 images.
# Keep other kernels installed, but select this kernel on every boot.
: "${KERNEL_VERSION:?KERNEL_VERSION must name the required kernel ABI}"
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
apt-get update
apt-get install -y "linux-image-${KERNEL_VERSION}" \
  "linux-headers-${KERNEL_VERSION}" "linux-modules-extra-${KERNEL_VERSION}"

mkdir -p /etc/default/grub.d
cat > /etc/default/grub.d/99-worker-images-kernel.cfg <<EOF
GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux ${KERNEL_VERSION}"
GRUB_DISABLE_SUBMENU=false
EOF
update-grub
grep -F "submenu 'Advanced options for Ubuntu'" /boot/grub/grub.cfg
grep -F "menuentry 'Ubuntu, with Linux ${KERNEL_VERSION}'" /boot/grub/grub.cfg
