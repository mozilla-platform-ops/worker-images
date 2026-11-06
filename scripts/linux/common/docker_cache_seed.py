#!/usr/bin/env python3

import argparse
import json
import re
from datetime import UTC, datetime
from pathlib import Path

TASK_ID = re.compile(r"^[A-Za-z0-9_-]{22}$")
SHA256 = re.compile(r"^[a-f0-9]{64}$")
FILE_CACHE_STATE = Path("/file-caches.json")
IMAGE_CACHE_STATE = Path("/d2g-image-cache.json")


def write_state(path, state):
    pending = path.with_name(path.name + ".tmp")
    pending.write_text(json.dumps(state, sort_keys=True) + "\n")
    pending.chmod(0o600)
    pending.replace(path)


def build(manifest_path, downloads_dir):
    images = json.loads(manifest_path.read_text())["images"]
    if not isinstance(images, list):
        raise TypeError("Docker cache images must be a list")
    downloads_dir = Path(downloads_dir).resolve()
    now = datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")
    file_caches = {}
    image_caches = {}

    for image in images:
        task_id = image["task_id"]
        digest = image["sha256"]
        image_id = image["image_id"]
        archive = image["archive"]
        archive_size = image["archive_size"]
        if not TASK_ID.fullmatch(task_id) or not SHA256.fullmatch(digest):
            raise ValueError("Invalid Docker artifact task ID or SHA256")
        if not SHA256.fullmatch(image_id):
            raise ValueError("Invalid Docker image ID")
        if archive != f"preloaded-{task_id}.tar.zst":
            raise ValueError("Invalid Docker artifact filename")
        if not isinstance(archive_size, int) or archive_size < 1:
            raise ValueError("Invalid Docker artifact size")

        archive_path = downloads_dir / archive
        if archive_path.stat().st_size != archive_size:
            raise ValueError(f"Docker artifact size mismatch: {archive_path}")
        cache_key = f"artifact:{task_id}:public/image.tar.zst"
        file_caches[cache_key] = {
            "created": now,
            "location": str(archive_path),
            "hits": 1,
            "key": cache_key,
            "sha256": digest,
            "in_use": False,
            "last_used": now,
        }
        image_caches[digest] = {"id": image_id, "name": image["image_name"]}

    write_state(FILE_CACHE_STATE, file_caches)
    write_state(IMAGE_CACHE_STATE, image_caches)
    print(f"Registered {len(images)} preloaded Docker image caches", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--downloads-dir", type=Path, required=True)
    args = parser.parse_args()
    build(args.manifest, args.downloads_dir)


if __name__ == "__main__":
    main()
