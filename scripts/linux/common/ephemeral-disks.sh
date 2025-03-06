#!/bin/bash

set -exv

disk_setup_script="/usr/local/bin/configure-generic-worker-disks"

cat << EOF > "${disk_setup_script}"
#!/bin/sh
# Main script logic
if mount | grep "instance_storage"; then
    echo "/mnt is already using an nvme0n* device."
else
    echo "/mnt is not using an nvme0n* device. Setting it up..."
    echo "Detecting available nvme0n* devices..."

    # Detect all nvme0n* devices using lsblk and filter their names
    NVME_DEVICES=\$(lsblk -dn -o NAME | grep nvme0n)
    NVME_COUNT=\$(echo "\$NVME_DEVICES" | wc -l)

    if [ "\$NVME_COUNT" -lt 1 ]; then
        echo "No nvme0n* devices found! Exiting..."
        exit 0
    fi

    echo "Found \$NVME_COUNT nvme0n* devices: \$NVME_DEVICES"

    if [ "\$NVME_COUNT" -eq 1 ]; then
        # Single disk setup
        echo "Setting up single disk configuration"
        DEVICE="/dev/\$NVME_DEVICES"
        
        # Create a physical volume directly on the device
        pvcreate "\$DEVICE"
        
        # Create a volume group
        vgcreate instance_storage "\$DEVICE"
    else
        # Multiple disk setup with RAID 0
        echo "Setting up RAID 0 configuration"
        DEVICE_LIST=\$(echo \$NVME_DEVICES | sed 's/ / \/dev\//g')
        mdadm --create /dev/md0 --level=0 --raid-devices=\$NVME_COUNT /dev/\$DEVICE_LIST
        
        # Create a physical volume on the RAID array
        pvcreate /dev/md0
        
        # Create a volume group
        vgcreate instance_storage /dev/md0
    fi

    # Create a logical volume
    lvcreate -l 100%VG -n lv_instance_storage instance_storage

    # Format the logical volume with ext4 filesystem
    mkfs.ext4 /dev/instance_storage/lv_instance_storage

    # Unmount the current /mnt if mounted
    umount /mnt || true

    # Mount the new logical volume to /mnt
    mount -o 'rw,relatime,errors=panic,data=writeback,nobarrier,commit=60' /dev/instance_storage/lv_instance_storage /mnt

    # Add the mount to /etc/fstab for persistence
    if ! grep -q "/mnt " /etc/fstab; then
        echo "/dev/instance_storage/lv_instance_storage /mnt ext4 rw,relatime,errors=panic,data=writeback,nobarrier,commit=60" | tee -a /etc/fstab
    fi

    echo "/mnt is now using nvme0n* devices."
fi

echo "Creating directories for generic-worker"
# tasksDir (/home)
mkdir -p /mnt/home
mount -o bind /mnt/home /home
# cachesDir
mkdir -p /mnt/generic-worker/caches
# downloadsDir
mkdir -p /mnt/generic-worker/downloads

echo "Creating docker specific directories"
mkdir -p /mnt/var/lib/docker

EOF

file "${disk_setup_script}"
chmod +x "${disk_setup_script}"

cat << EOF > /etc/systemd/system/generic-worker-disk-setup.service
[Unit]
Description=Taskcluster generic worker ephemeral disk setup
Before=worker.service docker.service

[Service]
Type=oneshot
ExecStart=${disk_setup_script}
User=root

[Install]
RequiredBy=multi-user.target
EOF

systemctl enable generic-worker-disk-setup
