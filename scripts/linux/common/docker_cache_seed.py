#!/usr/bin/env python3

import argparse
import json
import re
import subprocess
from datetime import UTC, datetime
from pathlib import Path

TASK_ID = re.compile(r"^[A-Za-z0-9_-]{22}$")
SHA256 = re.compile(r"^[a-f0-9]{64}$")
FILE_CACHE_STATE = Path("/file-caches.json")
IMAGE_CACHE_STATE = Path("/d2g-image-cache.json")


def read_state(path):
    try:
        state = json.loads(path.read_text())
    except FileNotFoundError:
        return {}
    except (OSError, json.JSONDecodeError) as error:
        print(f"Ignoring unreadable cache state {path}: {error}", flush=True)
        return {}
    if not isinstance(state, dict):
        print(f"Ignoring invalid cache state {path}", flush=True)
        return {}
    return state


def write_state(path, state):
    pending = path.with_name(path.name + ".tmp")
    pending.write_text(json.dumps(state, sort_keys=True) + "\n")
    pending.chmod(0o600)
    pending.replace(path)


def docker_image_exists(image_id, docker_command):
    try:
        result = subprocess.run(
            [
                *docker_command,
                "image",
                "inspect",
                "--format",
                "{{.Id}}",
                f"sha256:{image_id}",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return False
    if result.returncode:
        return False
    return result.stdout.strip().removeprefix("sha256:") == image_id


def install(manifest_path, downloads_dir, docker_command=("docker",)):
    manifest = json.loads(manifest_path.read_text())
    images = manifest.get("images", [])
    if not isinstance(images, list):
        raise TypeError("Docker cache manifest images must be a list")

    downloads_dir = Path(downloads_dir)
    downloads_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    downloads_dir.chmod(0o700)
    file_state = read_state(FILE_CACHE_STATE)
    image_state = read_state(IMAGE_CACHE_STATE)
    now = datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")

    for image in images:
        task_id = image["task_id"]
        digest = image["sha256"]
        archive_size = image["archive_size"]
        image_id = image["image_id"]
        image_name = image["image_name"]
        archive = image["archive"]
        if not TASK_ID.fullmatch(task_id) or not SHA256.fullmatch(digest):
            raise ValueError("Docker cache manifest has an invalid task ID or SHA256")
        if not SHA256.fullmatch(image_id):
            raise ValueError("Docker cache manifest has an invalid Docker image ID")
        if not isinstance(archive_size, int) or archive_size < 1:
            raise ValueError("Docker cache manifest has an invalid archive size")
        if archive != f"preloaded-{task_id}.tar.zst":
            raise ValueError("Docker cache archive does not match its task ID")

        cache_key = f"artifact:{task_id}:public/image.tar.zst"
        archive_path = downloads_dir / archive
        try:
            archive_valid = (
                archive_path.is_file() and archive_path.stat().st_size == archive_size
            )
        except OSError:
            archive_valid = False
        if archive_valid:
            file_state[cache_key] = {
                "created": now,
                "location": str(archive_path),
                "hits": 1,
                "key": cache_key,
                "sha256": digest,
                "in_use": False,
                "last_used": now,
            }
        else:
            file_state.pop(cache_key, None)
            print(f"Docker artifact cache unavailable: {task_id}", flush=True)

        if docker_image_exists(image_id, docker_command):
            image_state[digest] = {"id": image_id, "name": image_name}
        else:
            image_state.pop(digest, None)
            print(f"Docker image cache unavailable: {image_name}", flush=True)

    write_state(FILE_CACHE_STATE, file_state)
    write_state(IMAGE_CACHE_STATE, image_state)
    print(f"Registered {len(images)} preloaded Docker image cache entries", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("install",))
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--downloads-dir", type=Path, required=True)
    args = parser.parse_args()
    install(args.manifest, args.downloads_dir)


if __name__ == "__main__":
    main()
