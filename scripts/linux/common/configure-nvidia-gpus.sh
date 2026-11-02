#!/bin/bash

set -exv

gpu_setup_script="/usr/local/bin/configure-nvidia-gpus"

cat << EOF > "${gpu_setup_script}"
#!/bin/sh

set -e

if nvidia-smi > /dev/null 2>&1; then
    echo "NVIDIA GPUs detected. Running setup commands."
    nvidia-ctk system create-dev-char-symlinks --create-all
    # nvidia-cdi-refresh.service is disabled in the image because it loops on
    # GPU-less instances, so generate the CDI spec here instead.
    nvidia-ctk cdi generate --output=/var/run/cdi/nvidia.yaml || echo "Failed to generate NVIDIA CDI spec."
else
    echo "No NVIDIA GPUs detected."
fi
EOF

chmod +x "${gpu_setup_script}"

cat << EOF > /etc/systemd/system/nvidia-gpu-setup.service
[Unit]
Description=NVIDIA GPU setup for Taskcluster workers
Before=worker.service

[Service]
Type=oneshot
ExecStart=${gpu_setup_script}
User=root

[Install]
RequiredBy=multi-user.target
EOF

systemctl enable nvidia-gpu-setup
