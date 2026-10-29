#!/usr/bin/env python3
"""Build and restore Linux Gecko Hg and Git image caches."""

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
import time
from types import SimpleNamespace
from urllib.request import urlopen


SOURCE = "https://hg.mozilla.org/integration/autoland"
UPSTREAM = "https://hg.mozilla.org/mozilla-unified"
GIT_SOURCE = "https://github.com/mozilla-firefox/firefox"
QUEUE = "https://firefox-ci-tc.services.mozilla.com/api/queue/v1/task"
NODE = re.compile(r"[0-9a-f]{40}")
FORMATS = [
    "format.use-share-safe=no", "format.use-dirstate-v2=no",
    "format.use-persistent-nodemap=no", "format.use-delta-info-flags=no",
]
REQUIREMENTS = {"dotencode", "fncache", "generaldelta", "revlogv1", "store", "sparserevlog",
                "revlog-compression-zstd"}


def hg_command(hg, *args, capture=False):
    command = [hg, "--config", "ui.interactive=false", "--config", "progress.assume-tty=true"]
    for setting in FORMATS:
        command += ["--config", setting]
    return subprocess.run(command + list(map(str, args)), check=True, text=True,
                          env=dict(os.environ, HGPLAIN="1", HGRCPATH=os.devnull, PYTHONUNBUFFERED="1"),
                          stdout=subprocess.PIPE if capture else None).stdout


def seed_store(source, revision, sharebase, hg="hg", robustcheckout=None, upstream=None):
    """Create robustcheckout's root-node-keyed pool, without absolute share links."""
    sharebase.mkdir(parents=True, exist_ok=True)
    if any(sharebase.iterdir()):
        raise FileExistsError(f"Seed directory must be empty: {sharebase}")
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix=".seed-") as temp:
        clone = Path(temp) / "repository"
        if robustcheckout is None:
            robustcheckout = Path(temp) / "robustcheckout.py"
            url = f"{SOURCE}/raw-file/{revision}/taskcluster/scripts/robustcheckout.py"
            with urlopen(url, timeout=120) as response:
                robustcheckout.write_bytes(response.read())
        print(f"Cloning Gecko history at {revision}", flush=True)
        # robustcheckout requests a stream clone and retries transport failures.
        # Its --revision selects the target after cloning; it does not limit clone.
        hg_command(hg, "--config", f"extensions.robustcheckout={robustcheckout}",
                   "--config", "ui.clonebundles=true", "--config", "ui.clonebundlefallback=false",
                   "robustcheckout", "--noupdate", "--sharebase", sharebase.resolve(),
                   *(["--upstream", upstream] if upstream else []),
                   "--revision", revision, source, clone)
        resolved = hg_command(hg, "-R", clone, "log", "-r", revision, "-T", "{node}", capture=True).strip()
        if resolved != revision:
            raise ValueError("The Hg seed does not contain the selected autoland revision")
        root = hg_command(hg, "-R", clone, "log", "-r", "0", "-T", "{node}", capture=True).strip()
        if not NODE.fullmatch(root):
            raise ValueError("Mercurial did not return a root changeset")
        destination = sharebase / root
        requirements = set((destination / ".hg/requires").read_text().splitlines())
        if requirements - REQUIREMENTS or not {"dotencode", "fncache", "store"} <= requirements:
            raise ValueError(f"Unsupported Hg store requirements: {sorted(requirements)}")
        if (destination / ".hg/sharedpath").exists():
            raise ValueError("The seed store must not depend on another repository")
        (destination / ".hg/worker-image-seed").write_text(revision + "\n")
    print(f"Hg seed ready in {time.monotonic() - started:.1f}s", flush=True)
    return root


def initialize_run_task_cache(run_task, cache):
    # build() obtains this helper from the pinned, trusted autoland revision.
    wrapper = runpy.run_path(str(run_task))
    wrapper["configure_cache_posix"](
        str(cache), SimpleNamespace(pw_uid=1000, pw_name="worker"),
        SimpleNamespace(gr_gid=1000, gr_name="worker"), False, True,
    )


def cache_names(mode, level, digest=None):
    suffix = f"-hg58-v3-{digest[:20]}" if mode == "linux-d2g" else ""
    return [f"gecko-level-{level}-checkouts{suffix}"]


def prepare_cache(cache, mode):
    # Kept as a directory so boot is a rename on the same disk, not an extraction.
    if mode == "linux-d2g":
        subprocess.run(["chown", "-R", "1000:1000", str(cache)], check=True)


def same_disk(a, b):
    return a.stat().st_dev == b.stat().st_dev


def build_git(revision, mode, level, seed_root, decision, git_executable="git"):
    if not NODE.fullmatch(revision) or not re.fullmatch(r"[A-Za-z0-9_-]{22}", decision):
        raise ValueError("Use a full Git revision and its autoland decision task ID")
    if seed_root.exists():
        raise FileExistsError(f"Refusing to replace seed directory: {seed_root}")
    seed_root.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".git-seed-", dir=seed_root.parent) as temp:
        staging = Path(temp) / "seed"
        staging.mkdir()
        spec = {"source": GIT_SOURCE, "revision": revision, "mode": mode, "level": level,
                "created": datetime.now(timezone.utc).isoformat(), "cache_sources": {}}
        suffix = ""
        wrapper = staging / "run-task-git"
        if mode == "linux-d2g":
            import yaml

            artifact = f"{QUEUE}/{decision}/artifacts/public"
            with urlopen(f"{artifact}/run-task-git", timeout=120) as response:
                git_script = response.read()
            wrapper.write_bytes(git_script)
            with urlopen(f"{artifact}/parameters.yml", timeout=120) as response:
                repository_type = yaml.safe_load(response)["repository_type"]
            # Gecko hashes the decision's VCS helper, not each task's clone type.
            if repository_type == "hg":
                with urlopen(f"{artifact}/run-task-hg", timeout=120) as response:
                    cache_script = response.read()
            elif repository_type == "git":
                cache_script = git_script
            else:
                raise ValueError("Unknown decision repository type")
            suffix = "-v3-" + hashlib.sha256(cache_script).hexdigest()[:20]

        def git(*args, capture=False):
            return subprocess.run([git_executable, *map(str, args)], check=True, text=True,
                           stdout=subprocess.PIPE if capture else None,
                           env=dict(os.environ, GIT_CONFIG_NOSYSTEM="1",
                                    GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT="0")).stdout

        cache = staging / "shallow"
        repo = cache / "gecko"
        cache.mkdir()
        if mode == "linux-d2g":
            initialize_run_task_cache(wrapper, cache)
        git("init", repo)
        git("-C", repo, "remote", "add", "origin", GIT_SOURCE)
        # Depth 1 and no checked-out files: on pd-balanced, a full history made the task's
        # --depth=1 fetch take ~110 s, and checking 486k existing files took 2x longer than writing them.
        git("-C", repo, "fetch", "--progress", "--no-tags", "--depth=1", "origin", revision)
        git("-C", repo, "update-ref", "HEAD", revision)
        if git("-C", repo, "rev-parse", "--verify", "HEAD^{commit}", capture=True).strip() != revision:
            raise ValueError("The Git seed does not contain the selected autoland revision at HEAD")
        (repo / ".git/worker-image-seed").write_text(revision + "\n")
        spec["cache_sources"][f"gecko-level-{level}-checkouts-git-shallow{suffix}"] = "shallow"
        prepare_cache(cache, mode)
        spec["cache_names"] = list(spec["cache_sources"])
        (staging / "manifest.json").write_text(json.dumps(spec, indent=2) + "\n")
        staging.chmod(0o700)
        staging.rename(seed_root)


def build(revision, mode, level, seed_root, hg, robustcheckout=None):
    if not NODE.fullmatch(revision):
        raise ValueError("Use a full Hg changeset from the latest autoland decision task")
    if seed_root.exists():
        raise FileExistsError(f"Refusing to replace seed directory: {seed_root}")
    seed_root.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".hg-seed-", dir=seed_root.parent) as temp:
        staging = Path(temp) / "seed"
        cache = staging / "cache"
        cache.mkdir(parents=True)
        spec = {"source": SOURCE, "revision": revision, "mode": mode, "level": level,
                "created": datetime.now(timezone.utc).isoformat()}
        if mode == "linux-d2g":
            url = f"{SOURCE}/raw-file/{revision}/taskcluster/scripts/run-task"
            with urlopen(url, timeout=120) as response:
                content = response.read()
            wrapper = staging / "run-task-hg"
            wrapper.write_bytes(content)
            spec["run_task_sha256"] = hashlib.sha256(content).hexdigest()
            initialize_run_task_cache(wrapper, cache)
        store = "hg-shared" if mode == "linux-native" else "hg-store"
        spec["store_subdir"] = store
        spec["root_node"] = seed_store(SOURCE, revision, cache / store, hg, robustcheckout, upstream=UPSTREAM)
        spec["cache_names"] = cache_names(mode, level, spec.get("run_task_sha256"))
        prepare_cache(cache, mode)
        (staging / "manifest.json").write_text(json.dumps(spec, indent=2) + "\n")
        staging.chmod(0o700)
        staging.rename(seed_root)
    print(f"Gecko Hg seed ready: {seed_root}", flush=True)


def install(seed_root, destination_root, state_file, extra_seeds=()):
    """Run with the worker stopped. Keep all live worker state after first use."""
    if state_file.exists():
        print(f"Keeping Generic Worker state: {state_file}", flush=True)
        return
    entries = []
    names = set()
    sources = set()
    for root in (seed_root, *extra_seeds):
        spec = json.loads((root / "manifest.json").read_text())
        for name in spec["cache_names"]:
            source = spec.get("cache_sources", {}).get(name, "cache")
            # Each seed directory is moved, not copied, so it can back only one cache.
            if name in names or (root, source) in sources or source not in ("cache", "shallow"):
                raise ValueError("Duplicate cache name, shared seed directory, or invalid cache source")
            names.add(name)
            sources.add((root, source))
            entries.append((root, spec, name, source))
    state = {}
    destination_root.mkdir(parents=True, exist_ok=True)
    # Idle caches must not be accessible without a scoped task mount.
    destination_root.chmod(0o700)
    if any(not same_disk(root, destination_root) for root, *_ in entries):
        # Local-SSD pools: copying from the boot disk costs more than a cold clone, so skip.
        print(f"Seed is not on the {destination_root} disk; tasks will clone normally", flush=True)
        return
    for seed_root, spec, name, source in entries:
        git_cache = re.fullmatch(r"gecko-level-[13]-checkouts-git-shallow(?:-v3-[0-9a-f]{20})?", name)
        if not git_cache and not re.fullmatch(r"gecko-level-[13]-checkouts(?:-sparse)?(?:-hg58-v3-[0-9a-f]{20})?", name):
            raise ValueError("Invalid cache name in seed manifest")
        destination = destination_root / name
        started = time.monotonic()
        if destination.exists():
            # Only an earlier, interrupted install creates caches before the state file exists.
            print(f"Keeping checkout cache from an earlier install: {name}", flush=True)
        else:
            if spec["mode"] == "linux-d2g" and os.geteuid() != 0:
                raise PermissionError("Restore D2G seeds as root to preserve UID/GID 1000")
            print(f"Installing checkout cache: {name}", flush=True)
            # The seed is built into the trusted image, outside task-writable paths.
            (seed_root / source).rename(destination)
            print(f"Installed {name} in {time.monotonic() - started:.1f}s", flush=True)
        state[name] = [{"key": name, "location": str(destination.resolve()),
                        "created": spec["created"]}]
    state_file.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".hg-state-", dir=state_file.parent) as temp:
        pending = Path(temp) / "state.json"
        pending.write_text(json.dumps(state) + "\n")
        pending.chmod(0o600)
        os.link(pending, state_file)
    print(f"Registered checkout caches: {', '.join(state)}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    bake = commands.add_parser("build")
    bake.add_argument("--revision", required=True)
    bake.add_argument("--mode", choices=("linux-native", "linux-d2g"), required=True)
    bake.add_argument("--level", type=int, choices=(1, 3), default=1)
    bake.add_argument("--seed-root", type=Path, required=True)
    bake.add_argument("--hg", default="hg")
    git_bake = commands.add_parser("build-git")
    git_bake.add_argument("--revision", required=True)
    git_bake.add_argument("--decision", required=True)
    git_bake.add_argument("--mode", choices=("linux-native", "linux-d2g"), required=True)
    git_bake.add_argument("--level", type=int, choices=(1, 3), default=1)
    git_bake.add_argument("--seed-root", type=Path, required=True)
    git_bake.add_argument("--git", default="git")
    boot = commands.add_parser("install")
    boot.add_argument("--seed-root", type=Path, required=True)
    boot.add_argument("--destination-root", type=Path, required=True)
    boot.add_argument("--state-file", type=Path, required=True)
    boot.add_argument("--extra-seed-root", type=Path, action="append", default=[])
    args = parser.parse_args()
    if args.command == "build":
        build(args.revision, args.mode, args.level, args.seed_root, args.hg)
    elif args.command == "build-git":
        build_git(args.revision, args.mode, args.level, args.seed_root, args.decision, args.git)
    else:
        install(args.seed_root, args.destination_root, args.state_file, args.extra_seed_root)


if __name__ == "__main__":
    main()
