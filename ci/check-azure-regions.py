#!/usr/bin/env python3
"""Check gallery coverage using fxci-config's own pool expansion and image aliases.

Run with fxci-config's locked dependencies:
  uv run --frozen --no-dev --project ../fxci-config python ci/check-azure-regions.py ../fxci-config
"""

import argparse
import asyncio
from collections import defaultdict
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def normalize_region(region):
    result = re.sub(r"[\s-]", "", region.lower())
    if not re.fullmatch(r"[a-z0-9]+", result):
        raise ValueError(f"Invalid Azure region: {region!r}")
    return result


def image_key(provider, resource_group, gallery, name):
    return provider, resource_group.lower(), gallery.lower(), name.lower()


def pool_regions(pools, images):
    required = defaultdict(set)
    for pool in pools:
        if (
            pool.provider_id not in ("azure2", "azure_trusted")
            or pool.config["maxCapacity"] <= 0
        ):
            continue
        image = images[pool.config["image"]].get(pool.provider_id)
        # Older managed-image maps are not Compute Gallery images built here.
        if not isinstance(image, dict) or not image.get("name"):
            continue
        key = image_key(
            pool.provider_id, image["resource_group"], image["name"], image["name"]
        )
        required[key].update(normalize_region(r) for r in pool.config["locations"])
    return required


def coverage_difference(required, configured, build_region):
    expected = set(required) | {normalize_region(build_region)}
    actual = {normalize_region(r) for r in configured} | {
        normalize_region(build_region)
    }
    return (
        sorted(expected),
        sorted(actual),
        sorted(expected - actual),
        sorted(actual - expected),
    )


async def check(args):
    import yaml

    # Reuse the authoritative resolver instead of implementing keyed-by/variants/aliases here.
    sys.path.insert(0, str(args.fxci_config / "src"))
    os.chdir(args.fxci_config)
    from ciadmin.generate.ciconfig.environment import Environment
    from ciadmin.generate.ciconfig.worker_images import WorkerImage
    from ciadmin.generate.ciconfig.worker_pools import WorkerPool
    from ciadmin.generate.worker_pools import generate_pool_variants

    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    print(f"Region source: mozilla-releng/fxci-config@{revision}")
    environment = await Environment.get("firefoxci")
    required = pool_regions(
        generate_pool_variants(await WorkerPool.fetch_all(), environment),
        await WorkerImage.fetch_all(),
    )
    defaults = yaml.safe_load(
        (args.config_directory / "windows_production_defaults.yaml").read_text()
    )
    report = []
    for path in sorted(args.config_directory.glob("*.yaml")):
        config = yaml.safe_load(path.read_text())
        if not isinstance(config, dict) or "sharedimage" not in config:
            continue
        azure = defaults["azure"] | config.get("azure", {})
        shared = config["sharedimage"]
        provider = "azure_trusted" if path.stem.startswith("trusted-") else "azure2"
        key = image_key(
            provider,
            azure["managed_image_resource_group_name"],
            shared["gallery_name"],
            shared["image_name"],
        )
        if key not in required:
            print(
                f"{path.stem}: no active fxci-config pool references this gallery; not compared"
            )
            continue
        expected, actual, missing, extra = coverage_difference(
            required[key],
            azure.get("locations", []),
            azure.get("build_location", "centralus"),
        )
        report.append(
            dict(
                config=path.stem,
                expected=expected,
                actual=actual,
                missing=missing,
                extra=extra,
            )
        )
        if missing or extra:
            print(f"{path.stem}: missing={missing}, unused={extra}")
    if not report:
        raise ValueError(
            "No galleries matched fxci-config; refusing to report a passing comparison"
        )
    if args.report:
        args.report.write_text(
            json.dumps(dict(fxci_revision=revision, images=report), indent=2) + "\n"
        )
    failed = any(row["missing"] or row["extra"] for row in report)
    print(
        f"Compared {len(report)} galleries: {'region drift detected' if failed else 'coverage matches active pools'}"
    )
    return int(failed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fxci_config", type=lambda p: Path(p).resolve())
    parser.add_argument(
        "--config-directory",
        type=lambda p: Path(p).resolve(),
        default=Path(__file__).resolve().parents[1] / "config",
    )
    parser.add_argument("--report", type=lambda p: Path(p).resolve())
    return asyncio.run(check(parser.parse_args()))


if __name__ == "__main__":
    sys.exit(main())
