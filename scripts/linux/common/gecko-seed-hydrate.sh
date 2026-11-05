#!/bin/bash
set -euo pipefail

name=gecko_seed_ssd
fstrim /mnt
dmsetup message "$name" 0 hydration_threshold 1024
dmsetup message "$name" 0 hydration_batch_size 256
dmsetup message "$name" 0 enable_hydration
for ((attempt=0; attempt<180; attempt++)); do
    read -r -a status <<< "$(dmsetup status "$name")"
    [[ ${status[2]} == clone && ${status[6]} == */* ]]
    hydrated=${status[6]}
    if [[ ${hydrated%/*} == "${hydrated#*/}" ]]; then
        read -r -a table <<< "$(dmsetup table "$name")"
        source_device=$(readlink -f "/dev/block/${table[5]}")
        [[ $source_device == /dev/loop* ]]
        dmsetup suspend "$name"
        trap 'dmsetup resume "$name" || true' EXIT
        dmsetup load "$name" --table "0 ${table[1]} linear /dev/instance_storage/lv_instance_storage 0"
        dmsetup resume "$name"
        trap - EXIT
        losetup -d "$source_device"
        echo 'Gecko seed copy to SSD complete'
        exit 0
    fi
    sleep 5
done
echo 'Gecko seed copy to SSD timed out' >&2
exit 1
