#!/bin/bash
set -Eeuo pipefail
trap 'printf "Cache preload failed: exit=%s line=%s command=%s\n" "$?" "$LINENO" "$BASH_COMMAND" >&2' ERR

echo 'Preparing Docker storage'
apt-get install -y git python3-yaml lvm2
systemctl stop docker.service docker.socket
bash /tmp/docker-config.sh
bash /tmp/ephemeral-disks.sh
systemctl daemon-reload

root_url=https://firefox-ci-tc.services.mozilla.com
label="docker-image-${PRELOAD_IMAGE_LABEL}"
echo "Resolving autoland decision for $label"
decision=$(curl -fsSL --retry 5 "$root_url/api/index/v1/task/gecko.v2.autoland.latest.taskgraph.decision" | jq -er .taskId)
echo "Docker preload: decision=$decision label=$label"
task_id=$(curl -fsSL --retry 5 "$root_url/api/queue/v1/task/$decision/artifacts/public/label-to-taskid.json" | jq -er --arg l "$label" '.[$l] // error("Docker image label not found: \($l)")')
echo "Downloading Docker image: task=$task_id label=$label"
systemctl start docker
curl -fsSL --retry 5 -o /tmp/preload-image.tar.zst "$root_url/api/queue/v1/task/$task_id/artifacts/public/image.tar.zst"
echo "Loading Docker image $label"
docker load -i /tmp/preload-image.tar.zst
rm -f /tmp/preload-image.tar.zst
mkdir -p /etc/worker-images
echo "$label $task_id decision=$decision $(date -u +%FT%TZ)" >> /etc/worker-images/preloaded-docker-images.txt
docker images --digests

echo 'Preparing Gecko seed filesystem'
install -D -m 0755 /tmp/gecko_seed.py /usr/local/lib/worker-images/gecko_seed.py
install -m 0755 /tmp/gecko-seed-disks.sh /tmp/gecko-seed-hydrate.sh /usr/local/lib/worker-images/
modprobe dm-clone
systemctl stop docker.service docker.socket
if mountpoint -q /home || mountpoint -q /mnt; then
    echo 'Expected /home and /mnt on the image boot disk' >&2
    exit 1
fi
image=/opt/gecko-home.ext4
test ! -e "$image"
staging=$(mktemp -d /run/gecko-seed.XXXXXX)
truncate -s 32G "$image"
chmod 0600 "$image"
mkfs.ext4 -q -m 0 -E lazy_journal_init=1 "$image"
mount -o loop "$image" "$staging"
trap 'umount "$staging"; rmdir "$staging"' EXIT
cp -a /home "$staging/"
cp -a /mnt/. "$staging/"
python3 /usr/local/lib/worker-images/gecko_seed.py build \
    --mode "$GECKO_SEED_MODE" --level "$GECKO_SEED_LEVEL" --seed-root "$staging/home/gecko-git-seed"
fstrim "$staging"
umount "$staging"
e2fsck -fn "$image"
mount -o loop,ro "$image" "$staging"
python3 - "$staging/home/gecko-git-seed" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
manifest = json.loads((root / "manifest.json").read_text())
for name in manifest["cache_names"]:
    repo = root / name / "gecko"
    assert (repo / "mach").is_file()
    assert (repo / ".git/index").stat().st_ctime_ns == manifest["index_ctimes"][name]
PY

# Keep Packer's SSH connection usable after removing the duplicated home data.
ssh_backup=$(mktemp -d /run/gecko-ssh.XXXXXX)
find /home -mindepth 2 -maxdepth 2 -name .ssh -exec cp -a --parents '{}' "$ssh_backup/" \;
find /home /mnt -mindepth 1 -maxdepth 1 -exec rm -rf -- '{}' +
if [[ -d "$ssh_backup/home" ]]; then
    cp -a "$ssh_backup/home/." /home/
fi
rm -rf "$ssh_backup"

# Move the seed into the caches directory before the worker starts.
mkdir -p /etc/systemd/system/worker.service.d
cat > /etc/systemd/system/worker.service.d/gecko-seed.conf <<'EOF'
[Unit]
Requires=generic-worker-disk-setup.service
After=generic-worker-disk-setup.service
RequiresMountsFor=/home

[Service]
TimeoutStartSec=infinity
ExecStartPre=/usr/bin/python3 /usr/local/lib/worker-images/gecko_seed.py install --seed-root /home/gecko-git-seed --destination-root /home/generic-worker/caches --state-file /directory-caches.json
EOF
systemctl daemon-reload
