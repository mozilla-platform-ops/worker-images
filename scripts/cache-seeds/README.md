# Gecko Hg image seed (WIP)

This opt-in seed contains Gecko Mercurial history. It does not contain a working
checkout, Git data, pip packages, or other task dependencies. Hardware WIMs are
not changed.

Set the Packer variable `gecko_hg_seed_revision` to the full 40-character
`GECKO_HEAD_REV` from an Hg task in the latest autoland decision task graph:
`gecko.v2.autoland.latest.taskgraph.decision`. The source is fixed to
`https://hg.mozilla.org/integration/autoland`. An empty revision disables the
seed. Do not use `tip` or a moving branch name.

For example, add these arguments to the normal Packer build command:

```text
-var 'gecko_hg_seed_revision=<full-autoland-Hg-revision>'
```

For Azure ARM64, also set `-var 'gecko_hg_seed_level=3'` for a level-3 image;
the default is level 1. GCP selects level 1 or 3 from the Packer source name.
Do not enable this WIP on a pool with a different cache layout or trust domain.

## Windows cloud images

Puppet must set `HG_CACHE=C:\hg-cache` and give task users inherited write
access to `C:\hg-shared`. The seed script fails if that setting differs. It runs
after Puppet as SYSTEM, with Worker Runner stopped.

On x64, the image builder writes the Hg store directly under
`C:\hg-shared\<root-changeset>`. This is the pool that Gecko's `run-task` already
uses. No directory-cache state file or copy to D: is needed. The builder restores
inherited ACLs on the new store and sets its owner to SYSTEM.

On ARM64, Gecko uses `build/hg-store` inside a Generic Worker checkout cache.
The builder prepares independent full and sparse caches under `C:\caches` and
writes initial state to `C:\worker-runner\directory-caches.json`. These use
`gecko-level-<level>-checkouts` and `gecko-level-<level>-checkouts-sparse`.
Generic Worker grants task-user access when it mounts each cache.

Use the C: pool configuration from fxci-config. These changes do not convert
older D: pools or change tasksDir, cachesDir, or downloadsDir.

## Linux images

Linux seeds the full-checkout cache by default. No checkout option is needed
for the Hg trial. Autoland decision `W2W5EeeBSJu1jaEnKQkzAw` has 3,435 Linux
Docker-style Hg task definitions using the full cache and 453 using the sparse
cache. These are task definitions, not measured task volume or cache-hit rates.
Both checkout types work; only the full cache is preloaded by default.

For a later sparse-only trial, the override is:

```text
-var 'gecko_hg_seed_checkout=sparse'
```

Other cache names continue to use the normal cold-checkout path.

The image contains one gzip archive at
`/usr/local/share/gecko-hg-seed/cache.tar.gz`, outside `/home`. The unarchived
build copy is removed before image capture. Before Worker Runner starts, its
ExecStartPre hook extracts the selected cache directly into a temporary directory
under `/home/generic-worker/caches`, after the task disk is mounted. It renames
the completed directory on that same filesystem and writes initial
state to `/directory-caches.json`, because the existing worker service has no
WorkingDirectory and starts in `/`. It does not change either setting.
The existing local-SSD setup and ext4 filesystem stay unchanged. The archive is
not copied onto the SSD before extraction. D2G ownership is stored in the archive;
there is no separate recursive ownership pass at boot. Restore logs include the
archive size and elapsed time. This still transfers one store per new worker;
compression and end-to-end speed gains have not been measured on Gecko history.

Native tasks use `checkouts/hg-shared`. D2G tasks use `checkouts/hg-store` and
cache names with the `-hg58-v3-<run-task-hash>` suffix. The builder obtains
`run-task` from the pinned autoland revision, computes its SHA-256 suffix, and
uses its cache initializer. D2G seed files belong to UID/GID 1000:1000.

This D2G WIP is for in-tree images that run as worker:worker (1000:1000).
Do not enable it on a pool that uses the same cache names with other UIDs/GIDs.
External Docker images have a different cache suffix and do not use this seed.
A changed run-task hash causes a normal cache miss; rebuild the image to seed
the new names. There are no wildcard cache names.

## State and validation

The seed stores history only. `robustcheckout` creates the task checkout and
fetches missing changes. No absolute `.hg/sharedpath` from the image build is
stored in the seed. Full and sparse caches do not share mutable store files.

The installer never replaces an existing worker state file. Reimage to test a
new seed. Image creation fails if cache state is already present. Cache records
retain the seed's build time so later purge requests still apply. On POSIX,
the host cache parent is private (0700); tasks can access only mounted caches.
An interrupted install that leaves cache directories without state
fails closed; reimage that worker. Reserve disk space for one Linux runtime
store (two on Windows ARM64), the image seed, task checkouts, and subsequent changes.

Local checks:

```sh
python3 scripts/cache-seeds/test_gecko_hg.py
# On Linux as root, test with Gecko's pinned helpers too:
RUN_TASK=/path/to/run-task ROBUSTCHECKOUT=/path/to/robustcheckout.py \
  python3 scripts/cache-seeds/test_gecko_hg.py
```

The integration check uses a small local Hg repository. It checks the real
run-task cache requirements, UID/GID, full and sparse store reuse, later
revisions, and preservation of live state. It is not a full image test.

For the Linux trial, use a pool with local SSD and confirm its exact Hg cache
name, run-task hash, and UID/GID before building. Compare an unseeded image and
a seeded image with the same task and machine type. Record VM-request-to-first-
task-completion time, restore time, checkout time, later task times, and peak
disk use. Do not infer a speed gain from worker readiness alone.

Keep the PR in draft until cloud images pass validation. Use the latest
autoland decision task as the baseline. All tier-1 tasks must pass before a
production rollout. A new-image-only tier-1 regression blocks deployment.
