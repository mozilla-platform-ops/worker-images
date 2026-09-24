"""Small local-repository checks; optional run-task/robustcheckout integration.

python3 scripts/cache-seeds/test_gecko_hg.py
As root on Linux, set RUN_TASK and ROBUSTCHECKOUT to test Gecko's real helpers.
"""

import hashlib
from datetime import datetime
import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import gecko_hg as seed


class SeedTest(unittest.TestCase):
    def test_store_and_registration(self):
        for checkout in ("full", "sparse"):
            with self.subTest(checkout=checkout):
                self.check_store_and_registration(checkout)

    def check_store_and_registration(self, checkout):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o755)
            source = root / "source"
            seed.hg_command("hg", "init", source)
            (source / "tracked").write_text("first\n")
            (source / "profile").write_text("[include]\ntracked\n")
            seed.hg_command("hg", "-R", source, "add")
            seed.hg_command("hg", "-R", source, "commit", "-u", "test", "-m", "first")
            revision = seed.hg_command("hg", "-R", source, "log", "-r", ".", "-T", "{node}", capture=True)
            with patch.object(seed, "SOURCE", str(source)):
                seed.build(revision, "windows-x64", 1, root / "hg-shared", "hg")
                seed.build(revision, "windows-arm64", 1, root / "arm-seed", "hg")
            self.assertTrue((root / "hg-shared" / revision / ".hg").is_dir())
            self.assertFalse((root / "hg-shared/manifest.json").exists())
            seed.install(root / "arm-seed", root / "arm-caches", root / "arm-state.json")
            arm_state = json.loads((root / "arm-state.json").read_text())
            for name in seed.cache_names("windows-arm64", 1):
                self.assertTrue((Path(arm_state[name][0]["location"]) / "hg-store" / revision / ".hg").is_dir())
            wrapper = os.environ.get("RUN_TASK")
            mode = "linux-d2g" if wrapper else "linux-native"
            image = root / "image-seed"
            # Only substitute the download/source; build and install are real.
            with patch.object(seed, "SOURCE", str(source)):
                if wrapper:
                    with patch.object(seed, "urlopen", return_value=open(wrapper, "rb")):
                        seed.build(revision, mode, 3, image, "hg", checkout)
                else:
                    seed.build(revision, mode, 3, image, "hg", checkout)
            spec = json.loads((image / "manifest.json").read_text())
            self.assertTrue((image / "cache.tar.gz").is_file())
            self.assertFalse((image / "cache").exists())
            # The task needs a later revision than the image seed.
            (source / "tracked").write_text("second\n")
            seed.hg_command("hg", "-R", source, "commit", "-u", "test", "-m", "second")
            head = seed.hg_command("hg", "-R", source, "log", "-r", ".", "-T", "{node}", capture=True)
            if wrapper:
                digest = hashlib.sha256(Path(wrapper).read_bytes()).hexdigest()
                self.assertEqual(spec["cache_names"], [seed.cache_names(mode, 3, digest)[checkout == "sparse"]])
            self.assertEqual(spec["root_node"], revision)
            state = root / "directory-caches.json"
            seed.install(image, root / "caches", state)
            entries = json.loads(state.read_text())
            if os.name == "posix":
                self.assertEqual((root / "caches").stat().st_mode & 0o777, 0o700)
            self.assertEqual(len(entries), 1)
            self.assertEqual("sparse" in next(iter(entries)), checkout == "sparse")
            saved = state.read_bytes()
            seed.install(image, root / "caches", state)
            self.assertEqual(state.read_bytes(), saved)
            for name, caches in entries.items():
                cache = Path(caches[0]["location"])
                self.assertEqual(caches[0]["key"], name)
                self.assertEqual(caches[0]["created"], spec["created"])
                self.assertIsNotNone(datetime.fromisoformat(caches[0]["created"]).tzinfo)
                store = cache / spec["store_subdir"] / revision
                self.assertFalse((store / ".hg/sharedpath").exists())
                self.assertFalse((store / "tracked").exists())
                self.assertEqual(seed.hg_command("hg", "-R", store, "log", "-r", revision, "-T", "{node}", capture=True), revision)
                if wrapper:
                    configure = runpy.run_path(wrapper)["configure_cache_posix"]
                    self.assertFalse(configure(str(cache), SimpleNamespace(pw_uid=1000, pw_name="worker"),
                                               SimpleNamespace(gr_gid=1000, gr_name="worker"), False, True))
                    for parent, _, files in os.walk(cache):
                        for item in [Path(parent)] + [Path(parent) / f for f in files]:
                            self.assertEqual((item.stat().st_uid, item.stat().st_gid), (1000, 1000))
                extension = os.environ.get("ROBUSTCHECKOUT")
                if extension:
                    # Match Generic Worker's move into the task directory.
                    task_cache = root / name
                    cache.rename(task_cache)
                    pool = task_cache / spec["store_subdir"]
                    sentinel = pool / revision / ".hg/seed-was-reused"
                    sentinel.touch()
                    command = ["--config", f"extensions.robustcheckout={extension}",
                               "--config", "extensions.share=", "--config", "extensions.sparse=",
                               "robustcheckout", "--sharebase", pool, "--purge", "--revision", revision]
                    if "sparse" in name:
                        command += ["--sparseprofile", "profile"]
                    def checkout():
                        subprocess.run(["hg", *map(str, command), str(source), str(task_cache / "gecko")],
                                       check=True, user=1000 if wrapper else None,
                                       group=1000 if wrapper else None,
                                       env=dict(os.environ, HGPLAIN="1", HGRCPATH=os.devnull))
                    checkout()
                    self.assertTrue(sentinel.exists(), "robustcheckout replaced the seeded store")
                    self.assertEqual((task_cache / "gecko/tracked").read_text(), "first\n")
                    command[command.index("--revision") + 1] = head
                    checkout()
                    self.assertEqual((task_cache / "gecko/tracked").read_text(), "second\n")
                    self.assertTrue(sentinel.exists())

    def test_names_and_existing_state(self):
        self.assertEqual(seed.cache_names("windows-arm64", 1),
                         ["gecko-level-1-checkouts", "gecko-level-1-checkouts-sparse"])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "directory-caches.json"
            state.write_text('{"live": []}')
            seed.install(root / "missing-seed", root / "caches", state)
            self.assertEqual(state.read_text(), '{"live": []}')
            self.assertFalse((root / "caches").exists())
            with self.assertRaises(ValueError):
                seed.build("tip", "windows-x64", 1, root / "shared", "hg")
            self.assertFalse((root / "shared").exists())
            with self.assertRaises(ValueError):
                seed.build("a" * 40, "linux-native", 1, root / "image", "hg")
            self.assertFalse((root / "image").exists())

    def test_broken_archive_does_not_register_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            image = root / "image"
            image.mkdir()
            (image / "manifest.json").write_text(json.dumps({
                "mode": "linux-native", "cache_names": ["gecko-level-1-checkouts"],
            }))
            (image / "cache.tar.gz").write_bytes(b"incomplete archive")
            with self.assertRaises(subprocess.CalledProcessError):
                seed.install(image, root / "caches", root / "state.json")
            self.assertFalse((root / "state.json").exists())
            self.assertEqual(list((root / "caches").iterdir()), [])


if __name__ == "__main__":
    unittest.main()
