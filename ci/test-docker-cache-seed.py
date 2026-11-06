#!/usr/bin/env python3

import hashlib
import importlib.util
import json
import tempfile
from pathlib import Path
from unittest.mock import patch

script = (
    Path(__file__).resolve().parents[1] / "scripts/linux/common/docker_cache_seed.py"
)
spec = importlib.util.spec_from_file_location("docker_cache_seed", script)
assert spec and spec.loader
seed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(seed)


def check():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        downloads = root / "downloads"
        downloads.mkdir()
        task_id = "A" * 22
        image_id = "b" * 64
        archive_name = f"preloaded-{task_id}.tar.zst"
        archive = downloads / archive_name
        archive.write_bytes(b"docker image archive")
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        manifest = root / "manifest.json"
        manifest.write_text(
            json.dumps(
                {
                    "images": [
                        {
                            "task_id": task_id,
                            "archive": archive_name,
                            "sha256": digest,
                            "archive_size": archive.stat().st_size,
                            "image_id": image_id,
                            "image_name": "lint:latest",
                        }
                    ]
                }
            )
        )
        file_state = root / "file-caches.json"
        image_state = root / "d2g-image-cache.json"
        with (
            patch.object(seed, "FILE_CACHE_STATE", file_state),
            patch.object(seed, "IMAGE_CACHE_STATE", image_state),
            patch.object(seed, "docker_image_exists", return_value=True),
        ):
            seed.install(manifest, downloads)
        file_caches = json.loads(file_state.read_text())
        image_caches = json.loads(image_state.read_text())
        key = f"artifact:{task_id}:public/image.tar.zst"
        assert file_caches[key]["location"] == str(archive)
        assert file_caches[key]["sha256"] == digest
        assert file_caches[key]["last_used"]
        assert image_caches[digest] == {"id": image_id, "name": "lint:latest"}

        archive.unlink()
        with (
            patch.object(seed, "FILE_CACHE_STATE", file_state),
            patch.object(seed, "IMAGE_CACHE_STATE", image_state),
            patch.object(seed, "docker_image_exists", return_value=True),
        ):
            seed.install(manifest, downloads)
        assert key not in json.loads(file_state.read_text())
        assert digest in json.loads(image_state.read_text())

        archive.write_bytes(b"docker image archive")
        with (
            patch.object(seed, "FILE_CACHE_STATE", file_state),
            patch.object(seed, "IMAGE_CACHE_STATE", image_state),
            patch.object(seed, "docker_image_exists", return_value=False),
        ):
            seed.install(manifest, downloads)
        assert key in json.loads(file_state.read_text())
        assert digest not in json.loads(image_state.read_text())


def check_empty():
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        manifest = root / "manifest.json"
        manifest.write_text('{"images": []}\n')
        file_state = root / "file-caches.json"
        image_state = root / "d2g-image-cache.json"
        with (
            patch.object(seed, "FILE_CACHE_STATE", file_state),
            patch.object(seed, "IMAGE_CACHE_STATE", image_state),
            patch.object(seed, "docker_image_exists", side_effect=AssertionError),
        ):
            seed.install(manifest, root / "downloads")
        assert json.loads(file_state.read_text()) == {}
        assert json.loads(image_state.read_text()) == {}


if __name__ == "__main__":
    check()
    check_empty()
    print("Docker cache seed checks passed")
