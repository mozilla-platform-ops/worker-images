#!/bin/bash
set -euo pipefail

if [[ -z "${GECKO_HG_SEED_REVISION:-}" ]]; then
    echo 'Gecko Hg image seed is disabled'
    exit 0
fi

apt-get install -y mercurial
install -D -m 0755 /tmp/gecko_hg.py /usr/local/lib/worker-images/gecko_hg.py
python3 /usr/local/lib/worker-images/gecko_hg.py build \
    --revision "$GECKO_HG_SEED_REVISION" --mode "$GECKO_HG_SEED_MODE" \
    --level "$GECKO_HG_SEED_LEVEL" \
    --seed-root /usr/local/share/gecko-hg-seed

# Install after the task disk is mounted. Keep the worker's existing paths.
disk_dependency=''
if [[ "$GECKO_HG_SEED_MODE" == linux-d2g ]]; then
    disk_dependency='Requires=generic-worker-disk-setup.service
After=generic-worker-disk-setup.service'
fi
cat > /etc/systemd/system/gecko-hg-seed.service <<EOF
[Unit]
Description=Install the initial Gecko Mercurial cache
${disk_dependency}
RequiresMountsFor=/home
Before=worker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/lib/worker-images/gecko_hg.py install --seed-root /usr/local/share/gecko-hg-seed --destination-root /home/generic-worker/caches --state-file /directory-caches.json
RemainAfterExit=yes
EOF
mkdir -p /etc/systemd/system/worker.service.d
cat > /etc/systemd/system/worker.service.d/gecko-hg-seed.conf <<'EOF'
[Unit]
Requires=gecko-hg-seed.service
After=gecko-hg-seed.service
EOF
systemctl daemon-reload
