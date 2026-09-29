#!/bin/bash

set -euxo pipefail

: "${KERNEL_VERSION:?KERNEL_VERSION must name the required kernel ABI}"
test "$(uname -r)" = "$KERNEL_VERSION"
test -s "/boot/vmlinuz-${KERNEL_VERSION}"
test -s "/boot/initrd.img-${KERNEL_VERSION}"
grep -Fx "GRUB_DEFAULT=\"Advanced options for Ubuntu>Ubuntu, with Linux ${KERNEL_VERSION}\"" \
  /etc/default/grub.d/99-worker-images-kernel.cfg
grep -F "menuentry 'Ubuntu, with Linux ${KERNEL_VERSION}'" /boot/grub/grub.cfg
grep -F "set default=\"Advanced options for Ubuntu>Ubuntu, with Linux ${KERNEL_VERSION}\"" \
  /boot/grub/grub.cfg
modinfo -F vermagic v4l2loopback | grep -F "${KERNEL_VERSION} "
modprobe v4l2loopback
