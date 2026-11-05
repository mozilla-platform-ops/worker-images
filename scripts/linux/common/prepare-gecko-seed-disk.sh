#!/bin/bash
set -euo pipefail

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
