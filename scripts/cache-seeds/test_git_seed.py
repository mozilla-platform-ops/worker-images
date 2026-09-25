"""uv run scripts/cache-seeds/test_git_seed.py

Set RUN_TASK_GIT to test with Gecko's actual helper. On Linux as root, also
set RUN_TASK to test Docker-style cache requirements and archive ownership.
"""

import hashlib
import io
import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import gecko_hg as seed


class GitSeedTest(unittest.TestCase):
    def test_seed_and_run_task_reuse(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "source"
            git_env = dict(os.environ, GIT_CONFIG_GLOBAL=str(root / "gitconfig"),
                           GIT_CONFIG_NOSYSTEM="1")
            def git(*args):
                return subprocess.check_output(["git", *map(str, args)], env=git_env,
                                               text=True).strip()
            git("init", source)
            for value in ("first", "second"):
                (source / "tracked").write_text(value)
                git("-C", source, "add", ".")
                git("-C", source, "-c", "user.name=test", "-c", "user.email=test@example.com",
                    "commit", "-m", value)
            revision = git("-C", source, "rev-parse", "HEAD")
            helper = os.environ.get("RUN_TASK_GIT")
            hg_helper = os.environ.get("RUN_TASK")
            mode = "linux-d2g" if helper and hg_helper else "linux-native"
            modes = ("windows-x64", mode)
            for mode in modes:
                image = root / (mode + "-seed")
                def download(url, **kwargs):
                    if url.endswith("parameters.json"):
                        return io.BytesIO(b'{"repository_type":"hg"}')
                    return io.BytesIO(Path(helper if url.endswith("run-task-git") else hg_helper).read_bytes())
                with patch.object(seed, "GIT_SOURCE", source.as_uri()), patch.object(seed, "urlopen", download):
                    with patch.object(seed.subprocess, "run", wraps=subprocess.run) as commands:
                        seed.build_git(revision, mode, 1, image, "a" * 22)
                    self.assertEqual(sum("fetch" in call.args[0] for call in commands.call_args_list), 1)
                spec = json.loads((image / "manifest.json").read_text())
                if mode == "linux-d2g":
                    suffix = "-v3-" + hashlib.sha256(Path(hg_helper).read_bytes()).hexdigest()[:20]
                    self.assertTrue(all(name.endswith(suffix) for name in spec["cache_names"]))
                state = root / (mode + "-state.json")
                destination = root / (mode + "-caches")
                # Register a second seed in the same initial worker state file.
                other = root / (mode + "-other")
                (other / "cache").mkdir(parents=True)
                (other / "cache/marker").write_text("other seed")
                (other / "manifest.json").write_text(json.dumps({
                    "mode": "windows-arm64", "created": spec["created"],
                    "cache_names": ["gecko-level-1-checkouts"],
                }))
                seed.install(image, destination, state, [other])
                saved = state.read_bytes()
                seed.install(image, destination, state)
                self.assertEqual(state.read_bytes(), saved)
                entries = json.loads(saved)
                self.assertEqual(len(entries), 5 if mode.startswith("windows-") else 3)
                entries.pop("gecko-level-1-checkouts")
                # A later task revision must use the existing seed, not clone again.
                (source / "tracked").write_text(mode + " later")
                git("-C", source, "-c", "user.name=test", "-c", "user.email=test@example.com",
                    "commit", "-am", "later")
                head = git("-C", source, "rev-parse", "HEAD")
                for name, records in entries.items():
                    cache = Path(records[0]["location"])
                    repo = cache / ("src" if mode.startswith("windows-") else "gecko")
                    self.assertEqual((repo / ".git/shallow").exists(), "-shallow" in name)
                    self.assertFalse((repo / ".git/objects/info/alternates").exists())
                    self.assertFalse((repo / "tracked").exists())
                    self.assertEqual(git("-c", f"safe.directory={repo}", "-C", repo,
                                         "remote", "get-url", "origin"), source.as_uri())
                    marker = repo / ".git/worker-image-seed"
                    self.assertEqual(marker.read_text().strip(), revision)
                    if mode == "linux-d2g":
                        self.assertEqual((marker.stat().st_uid, marker.stat().st_gid), (1000, 1000))
                    if helper:
                        with patch.dict(os.environ, git_env):
                            checkout = runpy.run_path(helper)["git_checkout"]
                            checkout(str(repo), source.as_uri(), source.as_uri(), None, None,
                                     head, None, None, shallow="-shallow" in name)
                        self.assertEqual((repo / "tracked").read_text(), mode + " later")
                        self.assertEqual(marker.read_text().strip(), revision)

    def test_bad_revision_and_duplicate_state(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaises(ValueError):
                seed.build_git("tip", "windows-x64", 1, root / "image", "a" * 22)
            image = root / "image"
            image.mkdir()
            (image / "manifest.json").write_text(json.dumps({
                "cache_names": ["gecko-level-1-checkouts-git"],
            }))
            with self.assertRaises(ValueError):
                seed.install(image, root / "caches", root / "state", [image])
            self.assertFalse((root / "state").exists())


if __name__ == "__main__":
    unittest.main()
