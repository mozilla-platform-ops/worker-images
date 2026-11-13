#!/bin/bash
set -euo pipefail

image=/opt/gecko-home.ext4
if mountpoint -q /mnt; then
    exit 0
fi
mkdir -p /mnt
mapfile -t disks < <(find /dev/disk/by-id -regextype posix-extended -maxdepth 1 \
    -regex '.*/google-local-nvme-ssd-[0-9]+' | sort -V)
if (( ${#disks[@]} )); then
    modprobe dm-clone
    if ! vgs instance_storage >/dev/null 2>&1; then
        vgcreate -y instance_storage "${disks[@]}"
        metadata_mb=$((64 * ${#disks[@]}))
        lvcreate -L "${metadata_mb}M" -n clone_metadata instance_storage
        lvcreate -l 100%FREE -i "${#disks[@]}" -n lv_instance_storage instance_storage
        dd if=/dev/zero of=/dev/instance_storage/clone_metadata bs=1M count="$metadata_mb" status=none
    fi
    destination=/dev/instance_storage/lv_instance_storage
    metadata=/dev/instance_storage/clone_metadata
    sectors=$(blockdev --getsz "$destination")
    test "$((sectors * 512))" -ge "$(stat -c %s "$image")"
    truncate -s "$((sectors * 512))" "$image"
    origin=$(losetup --find --show --read-only "$image")
    dmsetup create gecko_seed_ssd --table "0 $sectors clone $metadata $destination $origin 8 1 no_hydration"
    device=/dev/mapper/gecko_seed_ssd
    mount -o rw,relatime,errors=panic,data=writeback,nobarrier,commit=60 "$device" /mnt
    resize2fs "$device"
    systemd-run --unit gecko-seed-hydrate \
        /usr/local/lib/worker-images/gecko-seed-hydrate.sh
else
    # Budget physical space, leaving room for OS writes. Never shrink on reboot.
    python3 - "$image" <<'PY'
import os
import sys

image = sys.argv[1]
root = os.statvfs(image)
info = os.stat(image)
capacity = info.st_blocks * 512 + root.f_bavail * root.f_frsize - 1024**3
capacity = capacity // 4096 * 4096
if capacity > info.st_size:
    os.truncate(image, capacity)
PY
    device=$(losetup --direct-io=on --find --show "$image")
    mount -o discard "$device" /mnt
    resize2fs "$device"
fi
# Preserve SSH keys installed by the guest agent before the bind mount.
cp -au /home/. /mnt/home/
mount --bind /mnt/home /home
mkdir -p /mnt/generic-worker/caches /mnt/generic-worker/downloads /mnt/var/lib/docker
df -h /home /mnt
