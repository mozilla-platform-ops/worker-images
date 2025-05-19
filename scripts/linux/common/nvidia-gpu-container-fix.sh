cat << EOF > /etc/systemd/system/nvidia-gpu-container-fix.service
[Unit]
Description=Create NVIDIA dev symlinks if NVIDIA driver is loaded
After=multi-user.target
ConditionPathExists=/proc/driver/nvidia/version

[Service]
Type=oneshot
ExecStart=/usr/bin/nvidia-ctk system create-dev-char-symlinks --create-all

[Install]
WantedBy=multi-user.target

EOF

systemctl enable nvidia-gpu-container-fix.service