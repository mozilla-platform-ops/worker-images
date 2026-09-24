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
NODE = re.compile(r"[0-9a-f]{40}")
FORMATS = [
    "format.use-share-safe=no", "format.use-dirstate-v2=no",
    "format.use-persistent-nodemap=no", "format.use-delta-info-flags=no",
    "format.revlog-compression=zlib",
]
REQUIREMENTS = {"dotencode", "fncache", "generaldelta", "revlogv1", "store", "sparserevlog"}


def hg_command(hg, *args, capture=False):
    command = [hg, "--config", "ui.interactive=false", "--config", "progress.assume-tty=true"]
    for setting in FORMATS:
        command += ["--config", setting]
    return subprocess.run(command + list(map(str, args)), check=True, text=True,
                          env=dict(os.environ, HGPLAIN="1", HGRCPATH=os.devnull),
                          stdout=subprocess.PIPE if capture else None).stdout


def seed_store(source, revision, sharebase, hg="hg"):
    """Create robustcheckout's root-node-keyed pool, without absolute share links."""
    sharebase.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".seed-", dir=sharebase) as temp:
        clone = Path(temp) / "repository"
        print(f"Cloning Gecko history at {revision}", flush=True)
        hg_command(hg, "clone", "--pull", "--noupdate", "--rev", revision, source, clone)
        requirements = set((clone / ".hg/requires").read_text().splitlines())
        if requirements - REQUIREMENTS or not {"dotencode", "fncache", "store"} <= requirements:
            raise ValueError(f"Unsupported Hg store requirements: {sorted(requirements)}")
        root = hg_command(hg, "-R", clone, "log", "-r", "0", "-T", "{node}", capture=True).strip()
        if not NODE.fullmatch(root):
            raise ValueError("Mercurial did not return a root changeset")
        hg_command(hg, "-R", clone, "verify")
        (clone / ".hg/worker-image-seed").write_text(revision + "\n")
        destination = sharebase / root
        if destination.exists():
            raise FileExistsError(f"Refusing to replace Hg store: {destination}")
        clone.rename(destination)
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


def build(revision, mode, level, seed_root, hg):
    if not NODE.fullmatch(revision):
        raise ValueError("Use a full Hg changeset from the latest autoland decision task")
    if mode == "windows-x64":
        seed_store(SOURCE, revision, seed_root, hg)
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
        spec["root_node"] = seed_store(SOURCE, revision, cache / store, hg)
        spec["cache_names"] = cache_names(mode, level, spec.get("run_task_sha256"))
        if mode.startswith("linux-"):
            spec["cache_names"] = spec["cache_names"][:1]
            # Store numeric ownership in the archive, not in a boot-time tree walk.
            def archive_owner(member):
                if mode == "linux-d2g":
                    member.uid = member.gid = 1000
                    member.uname = member.gname = ""
                return member
            with tarfile.open(staging / "cache.tar.gz", "w:gz", compresslevel=1) as archive:
                archive.add(cache, arcname=".", filter=archive_owner)
            shutil.rmtree(cache)
        (staging / "manifest.json").write_text(json.dumps(spec, indent=2) + "\n")
        staging.rename(seed_root)
    print(f"Gecko Hg seed ready: {seed_root}", flush=True)


def install(seed_root, destination_root, state_file):
    """Run with the worker stopped. Keep all live worker state after first use."""
    if state_file.exists():
        print(f"Keeping Generic Worker state: {state_file}", flush=True)
        return
    spec = json.loads((seed_root / "manifest.json").read_text())
    state = {}
    destination_root.mkdir(parents=True, exist_ok=True)
    if os.name == "posix":
        # Idle caches must not be accessible without a scoped task mount.
        destination_root.chmod(0o700)
    for name in spec["cache_names"]:
        relops_cache = spec["mode"] == "windows-arm64" and name == "relops-level-3-checkouts-sparse"
        if not relops_cache and not re.fullmatch(r"gecko-level-[13]-checkouts(?:-sparse)?(?:-hg58-v3-[0-9a-f]{20})?", name):
            raise ValueError("Invalid cache name in seed manifest")
        destination = destination_root / name
        if destination.exists():
            raise FileExistsError(f"Cache directory exists without worker state: {destination}")
        started = time.monotonic()
        print(f"Installing Gecko Hg cache: {name}", flush=True)
        with tempfile.TemporaryDirectory(prefix=".install-", dir=destination_root) as temp:
            cache = Path(temp) / "cache"
            if spec["mode"].startswith("linux-"):
                if spec["mode"] == "linux-d2g" and os.geteuid() != 0:
                    raise PermissionError("Restore D2G seeds as root to preserve UID/GID 1000")
                cache.mkdir()
                archive = seed_root / "cache.tar.gz"
                print(f"Restoring {archive.stat().st_size} archive bytes onto the task disk", flush=True)
                # This archive is built into the trusted image, outside task-writable paths.
                subprocess.run(["tar", "-xzf", str(archive), "--numeric-owner",
                                "-C", str(cache)], check=True)
            else:
                shutil.copytree(seed_root / "cache", cache)
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
    print(f"Registered Gecko Hg caches: {', '.join(state)}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    bake = commands.add_parser("build")
    bake.add_argument("--revision", required=True)
    bake.add_argument("--mode", choices=("linux-native", "linux-d2g", "windows-x64", "windows-arm64"), required=True)
    bake.add_argument("--level", type=int, choices=(1, 3), default=1)
    bake.add_argument("--seed-root", type=Path, required=True)
    bake.add_argument("--hg", default="hg")
    boot = commands.add_parser("install")
    boot.add_argument("--seed-root", type=Path, required=True)
    boot.add_argument("--destination-root", type=Path, required=True)
    boot.add_argument("--state-file", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "build":
        build(args.revision, args.mode, args.level, args.seed_root, args.hg)
    else:
        install(args.seed_root, args.destination_root, args.state_file)


if __name__ == "__main__":
    main()
