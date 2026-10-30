#!/bin/bash
set -euo pipefail

if [[ -z "${GECKO_GIT_SEED_REVISION:-}" ]]; then
    echo 'Gecko image seed is disabled'
    exit 0
fi

if [[ -e /directory-caches.json ]]; then
    echo 'Build the seed on a fresh image without Generic Worker cache state' >&2
    exit 1
fi

apt-get install -y mercurial git python3-yaml
install -D -m 0755 /tmp/gecko_hg.py /usr/local/lib/worker-images/gecko_hg.py
python3 /usr/local/lib/worker-images/gecko_hg.py build-git \
    --revision "$GECKO_GIT_SEED_REVISION" --decision "$GECKO_SEED_DECISION" \
    --mode "$GECKO_HG_SEED_MODE" --level "$GECKO_HG_SEED_LEVEL" \
    --seed-root /usr/local/share/gecko-git-seed

# Hg seed removed: slower than a cold clone on pd-balanced boot disks (235 s vs 200 s).

# Move the seeds into the caches directory before the worker starts.
disk_dependency=''
if [[ "$GECKO_HG_SEED_MODE" == linux-d2g ]]; then
    disk_dependency='Requires=generic-worker-disk-setup.service
After=generic-worker-disk-setup.service'
fi
mkdir -p /etc/systemd/system/worker.service.d
cat > /etc/systemd/system/worker.service.d/gecko-hg-seed.conf <<EOF
[Unit]
${disk_dependency}
RequiresMountsFor=/home

[Service]
TimeoutStartSec=infinity
ExecStartPre=/usr/bin/python3 /usr/local/lib/worker-images/gecko_hg.py install --seed-root /usr/local/share/gecko-git-seed --destination-root /home/generic-worker/caches --state-file /directory-caches.json
EOF
systemctl daemon-reload
