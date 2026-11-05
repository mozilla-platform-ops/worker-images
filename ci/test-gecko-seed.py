#!/usr/bin/env python3

import importlib.util
import json
import os
import subprocess
import tempfile
from pathlib import Path
from unittest.mock import patch

script = Path(__file__).resolve().parents[1] / "scripts/linux/common/gecko_seed.py"
spec = importlib.util.spec_from_file_location("gecko_seed", script)
assert spec and spec.loader
seed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(seed)


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def check(level, copied):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        source = root / "source"
        source.mkdir()
        git(source, "init", "-q", "-b", "autoland")
        git(source, "config", "user.name", "Seed test")
        git(source, "config", "user.email", "seed-test@example.invalid")
        git(source, "config", "commit.gpgsign", "false")
        (source / "stable").write_text("unchanged\n")
        (source / "changed").write_text("before\n")
        git(source, "add", ".")
        git(source, "commit", "-qm", "initial")
        (source / "changed").write_text("seed\n")
        git(source, "commit", "-qam", "seed revision")
        revision = git(source, "rev-parse", "HEAD")

        image_seed = root / "image-seed"
        with (
            patch.object(seed, "fetch", side_effect=AssertionError("Unpinned lookup")),
            patch.object(seed, "GIT_SOURCE", source.as_uri()),
        ):
            seed.build(
                "linux-native",
                level,
                image_seed,
                {"decision": "local-seed-test", "gecko_revision": revision},
            )
        names = json.loads((image_seed / "manifest.json").read_text())["cache_names"]
        expected = [
            f"gecko-level-{n}-checkouts-git-shallow" for n in sorted({level, 3})
        ]
        assert names == expected

        installed_seed = image_seed
        if copied:
            installed_seed = root / "copied-seed"
            subprocess.run(
                ["cp", "-a", str(image_seed), str(installed_seed)], check=True
            )
        caches = root / "caches"
        state = root / "directory-caches.json"
        with patch.object(seed, "git", wraps=seed.git) as commands:
            seed.install(installed_seed, caches, state)
        assert commands.call_count == (len(names) if copied else 0)
        assert set(json.loads(state.read_text())) == set(names)
        repo = caches / names[-1] / "gecko"
        assert git(repo, "rev-parse", "HEAD") == revision
        assert git(repo, "rev-list", "--count", "HEAD") == "1"
        assert git(repo, "rev-parse", "--is-shallow-repository") == "true"
        unchanged_time = (repo / "stable").stat().st_mtime_ns

        (source / "changed").write_text("new task revision\n")
        git(source, "commit", "-qam", "task revision")
        target = git(source, "rev-parse", "HEAD")
        trace = root / "fetch.trace"
        with patch.dict(os.environ, GIT_TRACE_PACKET=str(trace)):
            git(repo, "fetch", "--depth=1", "origin", target)
        assert f"fetch> have {revision}" in trace.read_text()
        git(repo, "checkout", "-f", "-B", "autoland", target)
        assert (repo / "changed").read_text() == "new task revision\n"
        assert (repo / "stable").stat().st_mtime_ns == unchanged_time
        assert (repo / ".git/worker-image-seed").read_text().strip() == revision
        if level == 1:
            other = caches / names[0] / "gecko"
            (repo / "stable").write_text("task edit\n")
            assert (other / "stable").read_text() == "unchanged\n"
            assert git(other, "rev-parse", "HEAD") == revision
        original_state = state.read_bytes()
        seed.install(installed_seed, caches, state)
        assert state.read_bytes() == original_state
        assert git(repo, "rev-parse", "HEAD") == target


if __name__ == "__main__":
    with (
        tempfile.TemporaryDirectory() as directory,
        patch.object(seed, "fetch", return_value=b"changed helper"),
    ):
        try:
            seed.build(
                "linux-d2g",
                3,
                Path(directory) / "seed",
                {
                    "decision": "local-seed-test",
                    "gecko_revision": "a" * 40,
                    "run_task_git_sha256": "0" * 64,
                },
            )
        except ValueError as error:
            assert "checksum changed" in str(error)
        else:
            raise AssertionError("Changed helper was accepted")
    for image_level in (1, 3):
        for copied_to_disk in (False, True):
            check(image_level, copied_to_disk)
    print("Gecko seed checks passed")
