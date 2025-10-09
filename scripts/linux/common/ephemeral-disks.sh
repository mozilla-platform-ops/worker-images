#!/bin/bash

set -exv

disk_setup_script="/usr/local/bin/configure-generic-worker-disks"

cat << EOF > "${disk_setup_script}"
#!/bin/sh

set -e

makedirs () {
    echo "Creating directories for generic-worker"
    # cachesDir
    mkdir -p /mnt/generic-worker/caches
    # downloadsDir
    mkdir -p /mnt/generic-worker/downloads

    echo "Creating docker specific directories"
    mkdir -p /mnt/var/lib/docker
}

# Main script logic
if mount | grep -q "instance_storage"; then
    echo "/mnt is already using a local device."
else
    echo "/mnt is not using a local SSD. Setting it up..."
    echo "Detecting available local SSDs..."

    set +e
    # This assumes we won't use more than 10 devices
    NVME_DEVICES=\$(ls /dev/disk/by-id/google-local-nvme-ssd-?)
    set -e
    NVME_COUNT=\$(echo "\$NVME_DEVICES" | wc -l)

    if [ -z "\$NVME_DEVICES" ]; then
        echo "No google-local-nvme-ssd devices found! Exiting..."
        makedirs
        exit 0
    fi

    echo "Found \$NVME_COUNT local SSD devices: \$NVME_DEVICES"

    # Create a volume group
    vgcreate -y instance_storage \${NVME_DEVICES}

    # Create a logical volume
    lvcreate -l 100%VG -i\${NVME_COUNT} -n lv_instance_storage instance_storage

    # Format the logical volume with ext4 filesystem
    mkfs.ext4 /dev/instance_storage/lv_instance_storage

    # Unmount the current /home and /mnt if mounted
    umount /home || :
    umount /mnt || :

    # Mount the new logical volume to /mnt
    mount -o 'rw,relatime,errors=panic,data=writeback,nobarrier,commit=60' /dev/instance_storage/lv_instance_storage /mnt

    # Bind-mount to /home (generic-worker's tasksDir)
    cp -a /home /mnt/
    mount -o bind /mnt/home /home

    # Add the mounts to /etc/fstab for persistence
    if ! cat /etc/fstab | grep "/mnt "; then
        cat >> /etc/fstab <<END
/dev/instance_storage/lv_instance_storage /mnt  ext4 rw,relatime,errors=panic,data=writeback,nobarrier,commit=60
/mnt/home                                 /home none bind
END
    fi

    echo "/mnt is now using local SSDs."
fi

makedirs

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
