#!/usr/bin/env python3
"""Build the Gecko Git seed into a Linux image and register it at boot."""

import argparse
import hashlib
import json
import os
import re
import runpy
import subprocess
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from types import SimpleNamespace
from urllib.request import urlopen

TC = "https://firefox-ci-tc.services.mozilla.com/api"
GIT_SOURCE = "https://github.com/mozilla-firefox/firefox"


def fetch(url):
    with urlopen(url, timeout=120) as response:
        return response.read()


def git(*args):
    subprocess.run(
        ["git", *map(str, args)],
        check=True,
        env=dict(
            os.environ,
            GIT_CONFIG_NOSYSTEM="1",
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_TERMINAL_PROMPT="0",
        ),
    )


def refresh_index(repo):
    owner = repo.stat()
    git("-c", f"safe.directory={repo}", "-C", repo, "update-index", "--refresh")
    os.chown(repo / ".git/index", owner.st_uid, owner.st_gid)


def build(mode, level, seed_root, inputs):
    decision = inputs["decision"]
    artifacts = f"{TC}/queue/v1/task/{decision}/artifacts/public"
    revision = inputs["gecko_revision"]
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError(f"Bad autoland Git revision in decision {decision}")
    # A failed build discards the VM, so a partial temp directory never reaches an image.
    temp = Path(tempfile.mkdtemp(dir=seed_root.parent))
    cache = temp / "shallow"
    repo = cache / "gecko"
    cache.mkdir()
    name = f"gecko-level-{level}-checkouts-git-shallow"
    if mode == "linux-d2g":
        # D2G cache names carry a hash of the decision's VCS helper, as Gecko computes it.
        run_task_git = fetch(f"{artifacts}/run-task-git")
        helper_hash = hashlib.sha256(run_task_git).hexdigest()
        if helper_hash != inputs["run_task_git_sha256"]:
            raise ValueError(f"run-task-git checksum changed in decision {decision}")
        name += "-v3-" + helper_hash[:20]
        wrapper = temp / "run-task-git"
        wrapper.write_bytes(run_task_git)
        runpy.run_path(str(wrapper))["configure_cache_posix"](
            str(cache),
            SimpleNamespace(pw_uid=1000, pw_name="worker"),
            SimpleNamespace(gr_gid=1000, gr_name="worker"),
            False,
            True,
        )
        wrapper.unlink()
    git("init", repo)
    git("-C", repo, "remote", "add", "origin", GIT_SOURCE)
    git("-C", repo, "fetch", "--progress", "--no-tags", "--depth=1", "origin", revision)
    git("-C", repo, "checkout", "-B", "autoland", revision)
    (repo / ".git/worker-image-seed").write_text(revision + "\n")
    if mode == "linux-d2g":
        subprocess.run(["chown", "-R", "1000:1000", str(cache)], check=True)
    cache.rename(temp / name)
    names = [name]
    if level == 1:
        names.append(name.replace("level-1", "level-3", 1))
        subprocess.run(
            ["cp", "-a", str(temp / name), str(temp / names[-1])], check=True
        )
    index_ctimes = {}
    for cache_name in names:
        repo = temp / cache_name / "gecko"
        refresh_index(repo)
        index_ctimes[cache_name] = (repo / ".git/index").stat().st_ctime_ns
    (temp / "manifest.json").write_text(
        json.dumps(
            {
                "cache_names": names,
                "created": datetime.now(UTC).isoformat(),
                "index_ctimes": index_ctimes,
            }
        )
        + "\n"
    )
    temp.chmod(0o700)
    temp.rename(seed_root)
    print(f"Gecko Git seed {name} at {revision} (decision {decision})", flush=True)


def install(seed_root, caches, state_file):
    """Run before the worker starts. Never touch live worker state."""
    if state_file.exists():
        return
    spec = json.loads((seed_root / "manifest.json").read_text())
    caches.mkdir(parents=True, exist_ok=True)
    caches.chmod(0o700)  # Idle caches must not be readable without a task mount.
    if seed_root.stat().st_dev != caches.stat().st_dev:
        print(
            f"Seed is not on the {caches} disk; tasks will clone normally", flush=True
        )
        return
    state = {}
    for name in spec["cache_names"]:
        destination = caches / name
        if not destination.exists():
            (seed_root / name).rename(destination)
        repo = destination / "gecko"
        if (repo / ".git/index").stat().st_ctime_ns != spec.get("index_ctimes", {}).get(
            name
        ):
            refresh_index(repo)
        state[name] = [
            {"key": name, "location": str(destination), "created": spec["created"]}
        ]
    pending = state_file.with_name(state_file.name + ".tmp")
    pending.write_text(json.dumps(state) + "\n")
    pending.chmod(0o600)
    pending.rename(state_file)
    print(f"Registered checkout caches: {', '.join(state)}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    bake = commands.add_parser("build")
    bake.add_argument("--mode", choices=("linux-native", "linux-d2g"), required=True)
    bake.add_argument("--level", type=int, choices=(1, 3), required=True)
    bake.add_argument("--seed-root", type=Path, required=True)
    bake.add_argument("--inputs", type=Path, required=True)
    boot = commands.add_parser("install")
    boot.add_argument("--seed-root", type=Path, required=True)
    boot.add_argument("--destination-root", type=Path, required=True)
    boot.add_argument("--state-file", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "build":
        build(
            args.mode, args.level, args.seed_root, json.loads(args.inputs.read_text())
        )
    else:
        install(args.seed_root, args.destination_root, args.state_file)


if __name__ == "__main__":
    main()
