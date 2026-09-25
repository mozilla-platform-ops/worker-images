#!/bin/bash
set -euo pipefail

if [[ -z "${GECKO_HG_SEED_REVISION:-}" ]]; then
    if [[ -n "${GECKO_GIT_SEED_REVISION:-}" ]]; then
        echo 'Git seeding requires the paired autoland Hg revision' >&2
        exit 1
    fi
    echo 'Gecko Hg image seed is disabled'
    exit 0
fi

if [[ -e /directory-caches.json ]]; then
    echo 'Build the seed on a fresh image without Generic Worker cache state' >&2
    exit 1
fi

apt-get install -y mercurial git python3-yaml
install -D -m 0755 /tmp/gecko_hg.py /usr/local/lib/worker-images/gecko_hg.py
python3 /usr/local/lib/worker-images/gecko_hg.py build \
    --revision "$GECKO_HG_SEED_REVISION" --mode "$GECKO_HG_SEED_MODE" \
    --level "$GECKO_HG_SEED_LEVEL" \
    --seed-root /usr/local/share/gecko-hg-seed

extra_seed=''
if [[ -n "${GECKO_GIT_SEED_REVISION:-}" ]]; then
    python3 /usr/local/lib/worker-images/gecko_hg.py build-git \
        --revision "$GECKO_GIT_SEED_REVISION" --decision "$GECKO_SEED_DECISION" \
        --mode "$GECKO_HG_SEED_MODE" --level "$GECKO_HG_SEED_LEVEL" \
        --seed-root /usr/local/share/gecko-git-seed
    extra_seed='--extra-seed-root /usr/local/share/gecko-git-seed'
fi

# Restore directly onto the mounted task disk before the worker starts.
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
ExecStartPre=/usr/bin/python3 /usr/local/lib/worker-images/gecko_hg.py install --seed-root /usr/local/share/gecko-hg-seed ${extra_seed} --destination-root /home/generic-worker/caches --state-file /directory-caches.json
EOF
systemctl daemon-reload
