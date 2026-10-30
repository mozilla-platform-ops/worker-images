#!/usr/bin/env python3
"""Build the Gecko Git seed into a Linux image and register it at boot."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import subprocess
import tempfile
from types import SimpleNamespace
from urllib.request import urlopen

import yaml

TC = "https://firefox-ci-tc.services.mozilla.com/api"
GIT_SOURCE = "https://github.com/mozilla-firefox/firefox"


def fetch(url):
    with urlopen(url, timeout=120) as response:
        return response.read()


def git(*args):
    subprocess.run(["git", *map(str, args)], check=True,
                   env=dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT="0"))


def build(mode, level, seed_root):
    decision = json.loads(fetch(f"{TC}/index/v1/task/gecko.v2.autoland.latest.taskgraph.decision"))["taskId"]
    artifacts = f"{TC}/queue/v1/task/{decision}/artifacts/public"
    params = yaml.safe_load(fetch(f"{artifacts}/parameters.yml"))
    revision = params["head_git_rev"]
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
        helper = fetch(f"{artifacts}/run-task-hg") if params["repository_type"] == "hg" else run_task_git
        name += "-v3-" + hashlib.sha256(helper).hexdigest()[:20]
        wrapper = temp / "run-task-git"
        wrapper.write_bytes(run_task_git)
        runpy.run_path(str(wrapper))["configure_cache_posix"](
            str(cache), SimpleNamespace(pw_uid=1000, pw_name="worker"),
            SimpleNamespace(gr_gid=1000, gr_name="worker"), False, True)
        wrapper.unlink()
    git("init", repo)
    git("-C", repo, "remote", "add", "origin", GIT_SOURCE)
    # Depth 1 and no checked-out files: a full clone or a checkout made the first task slower.
    git("-C", repo, "fetch", "--progress", "--no-tags", "--depth=1", "origin", revision)
    git("-C", repo, "update-ref", "HEAD", revision)
    (repo / ".git/worker-image-seed").write_text(revision + "\n")
    if mode == "linux-d2g":
        subprocess.run(["chown", "-R", "1000:1000", str(cache)], check=True)
    (temp / "manifest.json").write_text(json.dumps(
        {"cache_name": name, "created": datetime.now(timezone.utc).isoformat()}) + "\n")
    temp.chmod(0o700)
    temp.rename(seed_root)
    print(f"Gecko Git seed {name} at {revision} (decision {decision})", flush=True)


def install(seed_root, caches, state_file):
    """Run before the worker starts. Never touch live worker state."""
    if state_file.exists():
        return
    spec = json.loads((seed_root / "manifest.json").read_text())
    name = spec["cache_name"]
    caches.mkdir(parents=True, exist_ok=True)
    caches.chmod(0o700)  # Idle caches must not be readable without a task mount.
    if seed_root.stat().st_dev != caches.stat().st_dev:
        print(f"Seed is not on the {caches} disk; tasks will clone normally", flush=True)
        return
    destination = caches / name
    if not destination.exists():  # Exists only after an interrupted earlier install.
        (seed_root / "shallow").rename(destination)
    state = {name: [{"key": name, "location": str(destination), "created": spec["created"]}]}
    pending = state_file.with_name(state_file.name + ".tmp")
    pending.write_text(json.dumps(state) + "\n")
    pending.chmod(0o600)
    pending.rename(state_file)
    print(f"Registered checkout cache: {name}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    bake = commands.add_parser("build")
    bake.add_argument("--mode", choices=("linux-native", "linux-d2g"), required=True)
    bake.add_argument("--level", type=int, choices=(1, 3), required=True)
    bake.add_argument("--seed-root", type=Path, required=True)
    boot = commands.add_parser("install")
    boot.add_argument("--seed-root", type=Path, required=True)
    boot.add_argument("--destination-root", type=Path, required=True)
    boot.add_argument("--state-file", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "build":
        build(args.mode, args.level, args.seed_root)
    else:
        install(args.seed_root, args.destination_root, args.state_file)


if __name__ == "__main__":
    main()
