#!/usr/bin/env python3
"""Expand a completed Packer image's replicas; publish readiness only when complete."""

import argparse
import json
import subprocess
import time
from pathlib import Path


def az(*args):
    return json.loads(
        subprocess.check_output(["az", *args, "--output", "json"], text=True)
    )


def replication_complete(image, regions):
    summary = (image.get("replicationStatus") or {}).get("summary") or []
    states = {row["region"].replace(" ", "").lower(): row["state"] for row in summary}
    if image.get("provisioningState") == "Failed" or "Failed" in states.values():
        raise RuntimeError(f"Image replication failed: {summary}")
    return image.get("provisioningState") == "Succeeded" and all(
        states.get(region) == "Completed" for region in regions
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--timeout", type=int, default=90 * 60)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text(encoding="utf-8-sig"))
    regions = manifest["regions"]
    if not regions or not all(isinstance(r, str) and r.isalnum() for r in regions):
        raise ValueError("Expected nonempty normalized Azure target regions")
    image_id = manifest["image_id"]
    # Explicit versions only: never update whichever image happens to be latest.
    if not image_id.startswith("/subscriptions/") or "/versions/" not in image_id:
        raise ValueError("Expected a versioned Azure image resource ID")
    ready = args.manifest.with_name(args.manifest.stem + "-ready.json")
    ready.unlink(missing_ok=True)
    subprocess.run(
        [
            "az",
            "sig",
            "image-version",
            "update",
            "--ids",
            image_id,
            "--target-regions",
            *regions,
            "--no-wait",
            "--output",
            "none",
        ],
        check=True,
    )
    deadline = time.monotonic() + args.timeout
    while time.monotonic() < deadline:
        image = az(
            "sig",
            "image-version",
            "show",
            "--ids",
            image_id,
            "--expand",
            "ReplicationStatus",
        )
        if replication_complete(image, regions):
            manifest["replication_status"] = image["replicationStatus"]
            ready.write_text(json.dumps(manifest, indent=2) + "\n")
            print(f"Replication complete: {image_id}")
            return
        print(f"Waiting for replication: {image_id}", flush=True)
        time.sleep(30)
    raise TimeoutError(f"Replication incomplete; do not deploy {image_id}")


if __name__ == "__main__":
    main()
