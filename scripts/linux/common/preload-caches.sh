#!/bin/bash
set -Eeuo pipefail
trap 'printf "Cache preload failed: exit=%s line=%s command=%s\n" "$?" "$LINENO" "$BASH_COMMAND" >&2' ERR

echo 'Preparing Docker storage'
apt-get install -y git lvm2
systemctl stop docker.service docker.socket
bash /tmp/docker-config.sh
bash /tmp/ephemeral-disks.sh
systemctl daemon-reload

inputs=/tmp/preload-caches.json
downloads=/home/generic-worker/downloads
mkdir -p "$downloads"
chmod 0700 "$downloads"
images='[]'
image_count=$(jq -r '.docker_images | length' "$inputs")
if (( image_count > 0 )); then
    systemctl start docker
    while IFS= read -r input; do
        labels=$(jq -c '.docker_labels' <<<"$input")
        task_id=$(jq -er '.docker_task_id' <<<"$input")
        image_index=$(jq -er '.docker_index' <<<"$input")
        archive_name="preloaded-$task_id.tar.zst"
        archive="$downloads/$archive_name"
        echo "Docker preload: labels=$(jq -r 'join(",")' <<<"$labels") index=$image_index task=$task_id"
        curl -fsSL --retry 5 -o "$archive" "https://firefox-ci-tc.services.mozilla.com/api/queue/v1/task/$task_id/artifacts/public/image.tar.zst"
        chmod 0600 "$archive"
        sha256=$(sha256sum "$archive" | cut -d ' ' -f 1)
        archive_size=$(stat -c %s "$archive")
        load_output=$(docker load -i "$archive")
        image_name=$(sed -n 's/^Loaded image: //p' <<<"$load_output" | head -n 1)
        if [[ -z "$image_name" ]]; then
            echo "Docker did not report a loaded image for task $task_id" >&2
            exit 1
        fi
        image_id=$(docker image inspect --format '{{.Id}}' "$image_name")
        image_id=${image_id#sha256:}
        if [[ ! "$image_id" =~ ^[a-f0-9]{64}$ ]]; then
            echo "Docker returned an invalid image ID for $image_name" >&2
            exit 1
        fi
        images=$(jq -c \
            --argjson labels "$labels" \
            --arg task_id "$task_id" \
            --arg archive "$archive_name" \
            --arg sha256 "$sha256" \
            --arg archive_size "$archive_size" \
            --arg image_id "$image_id" \
            --arg image_name "$image_name" \
            '. + [{docker_labels:$labels, task_id:$task_id, archive:$archive, sha256:$sha256, archive_size:($archive_size|tonumber), image_id:$image_id, image_name:$image_name}]' \
            <<<"$images")
        echo "Loaded Docker image: name=$image_name id=$image_id sha256=$sha256"
    done < <(jq -c '.docker_images[]' "$inputs")
    docker images --digests
    cache_manifest=$(mktemp /tmp/preloaded-docker-cache.XXXXXX)
    jq -n --argjson images "$images" '{images:$images}' > "$cache_manifest"
    python3 /tmp/docker_cache_seed.py --manifest "$cache_manifest" --downloads-dir "$downloads"
    rm -f "$cache_manifest"
fi

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
    --mode "$GECKO_SEED_MODE" --level "$GECKO_SEED_LEVEL" --seed-root "$staging/home/gecko-git-seed" --inputs "$inputs"
available_bytes=$(df -B1 --output=avail "$staging" | tail -n 1 | tr -d ' ')
if (( available_bytes < 1073741824 )); then
    echo "Preloaded caches leave less than 1 GiB free in the 32 GiB seed filesystem: $available_bytes bytes" >&2
    exit 1
fi
echo "Cache seed free space: $available_bytes bytes"
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
