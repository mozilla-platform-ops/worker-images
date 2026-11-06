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
                            "archive_size": archive.stat().st_size,
                            "sha256": digest,
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
        ):
            seed.build(manifest, downloads)
        key = f"artifact:{task_id}:public/image.tar.zst"
        file_cache = json.loads(file_state.read_text())[key]
        assert file_cache["location"] == str(archive.resolve())
        assert file_cache["sha256"] == digest
        assert file_cache["in_use"] is False
        assert file_cache["last_used"]
        assert json.loads(image_state.read_text())[digest] == {
            "id": image_id,
            "name": "lint:latest",
        }

        archive.write_bytes(b"changed size")
        with (
            patch.object(seed, "FILE_CACHE_STATE", file_state),
            patch.object(seed, "IMAGE_CACHE_STATE", image_state),
        ):
            try:
                seed.build(manifest, downloads)
            except ValueError as error:
                assert "size mismatch" in str(error)
            else:
                raise AssertionError("Changed archive size was accepted")


if __name__ == "__main__":
    check()
    print("Docker cache seed checks passed")
