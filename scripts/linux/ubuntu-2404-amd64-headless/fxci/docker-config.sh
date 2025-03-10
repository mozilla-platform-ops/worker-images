#!/bin/sh

set -exv

# Configure docker to:
# 1) use /mnt for storage, which will be on fast ssds if available rather than
#    on the slower persistent drive
# 2) turn on ipv6
# 3) disable direct communication between containers

cat << EOF > /etc/docker/daemon.json
{
  "data-root": "/mnt/var/lib/docker",
  "storage-driver": "overlay2",
  "ipv6": true,
  "fixed-cidr-v6": "fd15:4ba5:5a2b:100a::/64",
  "icc": false,
  "iptables": true
}
EOF
