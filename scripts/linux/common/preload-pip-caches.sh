#!/bin/bash

set -euo pipefail

seed_root=/usr/local/share/generic-worker/cache-seeds
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT

# Seed one pure-Python wheel to check pip cache reuse on alpha workers.
python3 -m venv "$build_dir/venv"
mkdir -p "$build_dir/downloads" "$seed_root/gecko-level-3-pip"
"$build_dir/venv/bin/python" -m pip \
  --isolated \
  --disable-pip-version-check \
  --cache-dir "$seed_root/gecko-level-3-pip" \
  download \
  --index-url https://pypi.org/simple \
  --only-binary=:all: \
  --no-deps \
  --dest "$build_dir/downloads" \
  six==1.17.0

cp -a "$seed_root/gecko-level-3-pip" "$seed_root/gecko-level-1-pip"
chmod -R go-rwx "$seed_root"
