#!/usr/bin/env python3
"""Build and install an opt-in Gecko Mercurial history seed."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import subprocess
import tarfile
import tempfile
import time
from types import SimpleNamespace
from urllib.request import urlopen


SOURCE = "https://hg.mozilla.org/integration/autoland"
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


def seed_store(source, revision, sharebase, hg="hg", robustcheckout=None):
    """Create robustcheckout's root-node-keyed pool, without absolute share links."""
    sharebase.mkdir(parents=True, exist_ok=True)
    if any(sharebase.iterdir()):
        raise FileExistsError(f"Seed directory must be empty: {sharebase}")
    started = time.monotonic()
    # Only the disposable checkout is private. The store inherits its pool's ACL.
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
    names = [f"gecko-level-{level}-{name}{suffix}" for name in ("checkouts", "checkouts-sparse")]
    if mode == "windows-arm64":
        names.append("relops-level-3-checkouts-sparse")
    return names


def archive_cache(cache, mode):
    def owner(member):
        if mode == "linux-d2g":
            member.uid = member.gid = 1000
            member.uname = member.gname = ""
        return member
    with tarfile.open(cache.with_name(cache.name + ".tar.gz"), "w:gz", compresslevel=1) as archive:
        archive.add(cache, arcname=".", filter=owner)
    shutil.rmtree(cache)


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
            artifact = f"{QUEUE}/{decision}/artifacts/public"
            with urlopen(f"{artifact}/run-task-git", timeout=120) as response:
                git_script = response.read()
            wrapper.write_bytes(git_script)
            with urlopen(f"{artifact}/parameters.json", timeout=120) as response:
                repository_type = json.load(response)["repository_type"]
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

        checkout = "src" if mode.startswith("windows-") else "gecko"
        full = staging / "full" / checkout
        shallow = staging / "shallow" / checkout
        for name in ("full", "shallow"):
            cache = staging / name
            cache.mkdir()
            if mode == "linux-d2g":
                initialize_run_task_cache(wrapper, cache)
        git("init", full)
        git("-C", full, "remote", "add", "origin", GIT_SOURCE)
        git("-C", full, "fetch", "--progress", "--no-tags", "origin", revision)
        git("-C", full, "update-ref", "HEAD", revision)
        # file:// forces Git transport; no alternates or hardlinked object files.
        git("clone", "--progress", "--no-checkout", "--no-hardlinks", "--depth=1", full.resolve().as_uri(), shallow)
        git("-C", shallow, "remote", "set-url", "origin", GIT_SOURCE)
        for name, repo in (("full", full), ("shallow", shallow)):
            if git("-C", repo, "rev-parse", "--verify", "HEAD^{commit}", capture=True).strip() != revision:
                raise ValueError("The Git seed does not contain the selected autoland revision at HEAD")
            (repo / ".git/worker-image-seed").write_text(revision + "\n")
            cache_name = "checkouts-git" + ("-shallow" if name == "shallow" else "")
            spec["cache_sources"][f"gecko-level-{level}-{cache_name}{suffix}"] = name
            if mode.startswith("windows-"):
                spec["cache_sources"][f"relops-level-3-{cache_name}"] = name
            if mode.startswith("linux-"):
                archive_cache(staging / name, mode)
        spec["cache_names"] = list(spec["cache_sources"])
        (staging / "manifest.json").write_text(json.dumps(spec, indent=2) + "\n")
        staging.rename(seed_root)


def build(revision, mode, level, seed_root, hg, robustcheckout=None):
    if not NODE.fullmatch(revision):
        raise ValueError("Use a full Hg changeset from the latest autoland decision task")
    if mode == "windows-x64":
        seed_store(SOURCE, revision, seed_root, hg, robustcheckout)
        return
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
        spec["root_node"] = seed_store(SOURCE, revision, cache / store, hg, robustcheckout)
        spec["cache_names"] = cache_names(mode, level, spec.get("run_task_sha256"))
        if mode.startswith("linux-"):
            spec["cache_names"] = spec["cache_names"][:1]
            archive_cache(cache, mode)
        (staging / "manifest.json").write_text(json.dumps(spec, indent=2) + "\n")
        staging.rename(seed_root)
    print(f"Gecko Hg seed ready: {seed_root}", flush=True)


def install(seed_root, destination_root, state_file, extra_seeds=()):
    """Run with the worker stopped. Keep all live worker state after first use."""
    if state_file.exists():
        print(f"Keeping Generic Worker state: {state_file}", flush=True)
        return
    entries = []
    names = set()
    for root in (seed_root, *extra_seeds):
        spec = json.loads((root / "manifest.json").read_text())
        for name in spec["cache_names"]:
            source = spec.get("cache_sources", {}).get(name, "cache")
            if name in names or source not in ("cache", "full", "shallow"):
                raise ValueError("Duplicate cache name or invalid cache source")
            names.add(name)
            entries.append((root, spec, name, source))
    state = {}
    destination_root.mkdir(parents=True, exist_ok=True)
    if os.name == "posix":
        # Idle caches must not be accessible without a scoped task mount.
        destination_root.chmod(0o700)
    for seed_root, spec, name, source in entries:
        relops_cache = spec["mode"] == "windows-arm64" and name == "relops-level-3-checkouts-sparse"
        git_cache = re.fullmatch(r"(?:gecko-level-[13]|relops-level-3)-checkouts-git(?:-shallow)?(?:-v3-[0-9a-f]{20})?", name)
        if not (relops_cache or git_cache) and not re.fullmatch(r"gecko-level-[13]-checkouts(?:-sparse)?(?:-hg58-v3-[0-9a-f]{20})?", name):
            raise ValueError("Invalid cache name in seed manifest")
        destination = destination_root / name
        if destination.exists():
            raise FileExistsError(f"Cache directory exists without worker state: {destination}")
        started = time.monotonic()
        print(f"Installing checkout cache: {name}", flush=True)
        with tempfile.TemporaryDirectory(prefix=".install-", dir=destination_root) as temp:
            cache = Path(temp) / "cache"
            if spec["mode"].startswith("linux-"):
                if spec["mode"] == "linux-d2g" and os.geteuid() != 0:
                    raise PermissionError("Restore D2G seeds as root to preserve UID/GID 1000")
                cache.mkdir()
                archive = seed_root / f"{source}.tar.gz"
                print(f"Restoring {archive.stat().st_size} archive bytes onto the task disk", flush=True)
                # This archive is built into the trusted image, outside task-writable paths.
                subprocess.run(["tar", "-xzf", str(archive), "--numeric-owner",
                                "-C", str(cache)], check=True)
            else:
                shutil.copytree(seed_root / source, cache)
            cache.rename(destination)
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
    bake.add_argument("--mode", choices=("linux-native", "linux-d2g", "windows-x64", "windows-arm64"), required=True)
    bake.add_argument("--level", type=int, choices=(1, 3), default=1)
    bake.add_argument("--seed-root", type=Path, required=True)
    bake.add_argument("--hg", default="hg")
    git_bake = commands.add_parser("build-git")
    git_bake.add_argument("--revision", required=True)
    git_bake.add_argument("--decision", required=True)
    git_bake.add_argument("--mode", choices=("linux-native", "linux-d2g", "windows-x64", "windows-arm64"), required=True)
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
