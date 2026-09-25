"""Small local-repository checks; optional run-task/robustcheckout integration.

uv run scripts/cache-seeds/test_gecko_hg.py
As root on Linux, set RUN_TASK and ROBUSTCHECKOUT to test Gecko's real helpers.
"""

import hashlib
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from datetime import datetime
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from urllib.parse import urlsplit
from urllib.request import urlopen

import gecko_hg as seed


class SeedTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.helpers = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.helpers.cleanup)
        cls.extension = os.environ.get("ROBUSTCHECKOUT")
        if not cls.extension:
            cls.extension = Path(cls.helpers.name) / "robustcheckout.py"
            url = (f"{seed.SOURCE}/raw-file/6978ac4b671864859416a7e5487211832eba1498/"
                   "taskcluster/scripts/robustcheckout.py")
            with urlopen(url, timeout=120) as response:
                cls.extension.write_bytes(response.read())

    def test_bundle_clone_and_revision_check(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            seed.hg_command("hg", "init", source)
            (source / "tracked").write_text("first\n")
            seed.hg_command("hg", "-R", source, "add")
            seed.hg_command("hg", "-R", source, "commit", "-u", "test", "-m", "first")
            revision = seed.hg_command("hg", "-R", source, "log", "-r", ".", "-T", "{node}", capture=True)
            seed.hg_command("hg", "-R", source, "bundle", "--all", "--type", "none-v2;stream=v2", root / "seed.hg")
            (source / "tracked").write_text("second\n")
            seed.hg_command("hg", "-R", source, "commit", "-u", "test", "-m", "second")
            downloads = []
            class Handler(SimpleHTTPRequestHandler):
                def do_GET(self):
                    downloads.append(self.path)
                    if len(downloads) == 1:
                        content = (root / "seed.hg").read_bytes()
                        self.send_response(200)
                        self.send_header("Content-Length", str(len(content)))
                        self.end_headers()
                        self.wfile.write(content[:len(content) // 2])
                        return
                    super().do_GET()
            with ThreadingHTTPServer(("127.0.0.1", 0), partial(Handler, directory=str(root))) as server:
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                bundle_url = f"http://127.0.0.1:{server.server_port}/seed.hg"
                (source / ".hg/clonebundles.manifest").write_text(f"{bundle_url} BUNDLESPEC=none-v2;stream=v2\n")
                try:
                    with subprocess.Popen(
                        ["hg", "--config", "extensions.clonebundles=", "-R", str(source),
                         "serve", "--address", "127.0.0.1", "--port", "0", "--print-url"],
                        stdout=subprocess.PIPE, text=True,
                        env=dict(os.environ, HGRCPATH=os.devnull, PYTHONUNBUFFERED="1"),
                    ) as remote:
                        try:
                            url = remote.stdout.readline().strip()
                            self.assertTrue(url.startswith("http://"), url)
                            url = f"http://127.0.0.1:{urlsplit(url).port}/"
                            with patch.object(seed, "hg_command", wraps=seed.hg_command) as command:
                                node = seed.seed_store(url, revision, root / "pool", robustcheckout=self.extension)
                            (root / "seed.hg").write_bytes(b"broken bundle")
                            with self.assertRaises(subprocess.CalledProcessError):
                                seed.seed_store(url, revision, root / "broken", robustcheckout=self.extension)
                            self.assertEqual(list((root / "broken").glob("*/.hg/worker-image-seed")), [])
                        finally:
                            remote.terminate()
                            remote.wait(timeout=10)
                finally:
                    server.shutdown()
                    thread.join(timeout=10)
            self.assertGreaterEqual(downloads.count("/seed.hg"), 3)
            clone_args = next(call.args for call in command.call_args_list if "robustcheckout" in call.args)
            self.assertIn("ui.clonebundles=true", clone_args)
            self.assertIn("ui.clonebundlefallback=false", clone_args)
            self.assertNotIn("--rev", clone_args)
            self.assertIn("--noupdate", clone_args)
            self.assertFalse(any("verify" in call.args for call in command.call_args_list))
            store = root / "pool" / node
            self.assertEqual((store / ".hg/worker-image-seed").read_text().strip(), revision)
            self.assertFalse((store / "tracked").exists())
            self.assertIn("revlog-compression-zstd", (store / ".hg/requires").read_text())
            self.assertNotEqual(seed.hg_command("hg", "-R", store, "log", "-r", "tip",
                                               "-T", "{node}", capture=True), revision)
            with self.assertRaises(subprocess.CalledProcessError):
                seed.seed_store(str(source), "e" * 40, root / "missing", robustcheckout=self.extension)
            self.assertEqual(list((root / "missing").glob("*/.hg/worker-image-seed")), [])
            with self.assertRaises(FileExistsError):
                seed.seed_store(str(source), revision, root / "pool", robustcheckout=self.extension)

    def test_latest_autoland_revision(self):
        resolve = runpy.run_path(str(Path(__file__).resolve().parents[2] / "ci/resolve-gecko-hg-seed.py"))["hg_revision"]
        def task(repo, revision):
            return {"task": {"payload": {"env": {
                "GECKO_HEAD_REPOSITORY": repo, "GECKO_HEAD_REV": revision,
            }}}}
        graph = {"hg": task(seed.SOURCE, "a" * 40), "git": task("https://github.com/mozilla-firefox/firefox", "b" * 40)}
        self.assertEqual(resolve(graph), "a" * 40)
        self.assertEqual(resolve(graph, "https://github.com/mozilla-firefox/firefox"), "b" * 40)
        for invalid in ({}, {"hg": task(seed.SOURCE, "tip")},
                        dict(graph, other=task(seed.SOURCE, "c" * 40))):
            with self.assertRaises(ValueError):
                resolve(invalid)

    def test_store_and_registration(self):
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
                seed.build(revision, "windows-x64", 1, root / "hg-shared", "hg", self.extension)
                with patch.object(seed, "seed_store", wraps=seed.seed_store) as clone:
                    seed.build(revision, "windows-arm64", 1, root / "arm-seed", "hg", self.extension)
                    self.assertEqual(clone.call_count, 1)
            self.assertTrue((root / "hg-shared" / revision / ".hg").is_dir())
            self.assertFalse((root / "hg-shared/manifest.json").exists())
            seed.install(root / "arm-seed", root / "arm-caches", root / "arm-state.json")
            arm_state = json.loads((root / "arm-state.json").read_text())
            self.assertEqual(set(arm_state), set(seed.cache_names("windows-arm64", 1)))
            arm_stores = []
            for name in seed.cache_names("windows-arm64", 1):
                store = Path(arm_state[name][0]["location"]) / "hg-store" / revision / ".hg"
                self.assertTrue(store.is_dir())
                for other in arm_stores:
                    self.assertFalse(os.path.samefile(store / "store/00changelog.i", other / "store/00changelog.i"))
                arm_stores.append(store)
            # A write in the RelOps cache must not change either Gecko cache.
            (arm_stores[-1] / "worker-image-seed").write_text("changed by RelOps task\n")
            for store in arm_stores[:-1]:
                self.assertEqual((store / "worker-image-seed").read_text().strip(), revision)
            wrapper = os.environ.get("RUN_TASK")
            mode = "linux-d2g" if wrapper else "linux-native"
            image = root / "image-seed"
            # Only substitute the download/source; build and install are real.
            with patch.object(seed, "SOURCE", str(source)):
                if wrapper:
                    with patch.object(seed, "urlopen", return_value=open(wrapper, "rb")):
                        seed.build(revision, mode, 3, image, "hg", self.extension)
                else:
                    seed.build(revision, mode, 3, image, "hg", self.extension)
            spec = json.loads((image / "manifest.json").read_text())
            self.assertTrue((image / "cache.tar.gz").is_file())
            self.assertFalse((image / "cache").exists())
            # The task needs a later revision than the image seed.
            (source / "tracked").write_text("second\n")
            seed.hg_command("hg", "-R", source, "commit", "-u", "test", "-m", "second")
            head = seed.hg_command("hg", "-R", source, "log", "-r", ".", "-T", "{node}", capture=True)
            if wrapper:
                digest = hashlib.sha256(Path(wrapper).read_bytes()).hexdigest()
                self.assertEqual(spec["cache_names"], seed.cache_names(mode, 3, digest)[:1])
            self.assertEqual(spec["root_node"], revision)
            state = root / "directory-caches.json"
            seed.install(image, root / "caches", state)
            entries = json.loads(state.read_text())
            if os.name == "posix":
                self.assertEqual((root / "caches").stat().st_mode & 0o777, 0o700)
            self.assertEqual(len(entries), 1)
            self.assertNotIn("sparse", next(iter(entries)))
            saved = state.read_bytes()
            seed.install(image, root / "caches", state)
            self.assertEqual(state.read_bytes(), saved)
            for name, caches in entries.items():
                cache = Path(caches[0]["location"])
                self.assertEqual(caches[0]["key"], name)
                self.assertEqual(caches[0]["created"], spec["created"])
                self.assertIsNotNone(datetime.fromisoformat(caches[0]["created"]).tzinfo)
                store = cache / spec["store_subdir"] / revision
                self.assertEqual((store / ".hg/worker-image-seed").read_text().strip(), revision)
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
                extension = self.extension
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
                    def checkout(check_seed=False):
                        checkout_command = ["hg", *map(str, command), str(source), str(task_cache / "gecko")]
                        if check_seed:
                            checkout_command = [sys.executable, str(Path(__file__).with_name("benchmark.py")),
                                                "--store", str(pool / revision),
                                                "--checkout", str(task_cache / "gecko"),
                                                "--seed-revision", revision, "--", *checkout_command]
                        subprocess.run(checkout_command,
                                       check=True, user=1000 if wrapper else None,
                                       group=1000 if wrapper else None,
                                       env=dict(os.environ, HGPLAIN="1", HGRCPATH=os.devnull))
                    checkout(check_seed=True)
                    self.assertTrue(sentinel.exists(), "robustcheckout replaced the seeded store")
                    self.assertEqual((task_cache / "gecko/tracked").read_text(), "first\n")
                    command[command.index("--revision") + 1] = head
                    checkout()
                    self.assertEqual((task_cache / "gecko/tracked").read_text(), "second\n")
                    self.assertTrue(sentinel.exists())

    def test_names_and_existing_state(self):
        self.assertEqual(seed.cache_names("windows-arm64", 1),
                         ["gecko-level-1-checkouts", "gecko-level-1-checkouts-sparse",
                          "relops-level-3-checkouts-sparse"])
        self.assertEqual(seed.cache_names("windows-arm64", 3),
                         ["gecko-level-3-checkouts", "gecko-level-3-checkouts-sparse",
                          "relops-level-3-checkouts-sparse"])
        self.assertEqual(seed.cache_names("linux-native", 1),
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
