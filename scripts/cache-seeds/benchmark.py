"""Time a real checkout command and check whether it keeps the image seed.

Run inside the task, after its cache mount. This does not submit tasks or prove
that a worker is fresh. Verify worker history and image identity separately.
"""

import argparse
import json
from pathlib import Path
import subprocess
import time


def benchmark(store, checkout, seed_revision, command):
    if not command:
        raise ValueError("A run-task checkout command is required")
    if checkout.exists():
        raise ValueError("The checkout is already present; this is not a cold checkout")
    marker = store / ".hg/worker-image-seed"
    before = None
    if seed_revision:
        before = marker.read_bytes()
        if before.decode().strip() != seed_revision:
            raise ValueError("The mounted store does not match the image seed")
    elif store.exists():
        raise ValueError("The unseeded baseline already has an Hg store")

    started = time.monotonic()
    result = subprocess.run(command, check=False)
    elapsed = time.monotonic() - started
    reused = bool(before and marker.is_file() and marker.read_bytes() == before)
    sharedpath = checkout / ".hg/sharedpath"
    shared_store = None
    if sharedpath.is_file():
        shared_store = (sharedpath.parent / sharedpath.read_text().strip()).resolve()
    passed = (result.returncode == 0 and (store / ".hg").is_dir()
              and shared_store == (store / ".hg").resolve())
    if seed_revision:
        passed = passed and reused
    return {
        "mode": "seeded" if seed_revision else "unseeded",
        "seed_revision": seed_revision,
        "seed_reused": reused,
        "checkout_seconds": round(elapsed, 3),
        "command_exit_code": result.returncode,
        "passed": passed,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--store", type=Path, required=True,
                        help="Root-node-keyed store inside the task's mounted cache")
    parser.add_argument("--checkout", type=Path, required=True)
    parser.add_argument("--seed-revision", help="Image seed revision; omit for the cold baseline")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    result = benchmark(args.store, args.checkout, args.seed_revision, command)
    print("HG_CACHE_BENCHMARK " + json.dumps(result), flush=True)
    raise SystemExit(0 if result["passed"] else 1)


if __name__ == "__main__":
    main()
