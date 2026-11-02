#!/bin/bash
set -euo pipefail

apt-get install -y git python3-yaml
install -D -m 0755 /tmp/gecko_seed.py /usr/local/lib/worker-images/gecko_seed.py
python3 /usr/local/lib/worker-images/gecko_seed.py build \
    --mode "$GECKO_SEED_MODE" --level "$GECKO_SEED_LEVEL" --seed-root /usr/local/share/gecko-git-seed

# Move the seed into the caches directory before the worker starts.
disk_dependency=''
if [[ "$GECKO_SEED_MODE" == linux-d2g ]]; then
    disk_dependency='Requires=generic-worker-disk-setup.service
After=generic-worker-disk-setup.service'
fi
mkdir -p /etc/systemd/system/worker.service.d
cat > /etc/systemd/system/worker.service.d/gecko-seed.conf <<EOF
[Unit]
${disk_dependency}
RequiresMountsFor=/home

[Service]
TimeoutStartSec=infinity
ExecStartPre=/usr/bin/python3 /usr/local/lib/worker-images/gecko_seed.py install --seed-root /usr/local/share/gecko-git-seed --destination-root /home/generic-worker/caches --state-file /directory-caches.json
EOF
systemctl daemon-reload
