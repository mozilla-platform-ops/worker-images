# Gecko Hg and Git image seeds (WIP)

These opt-in seeds contain Gecko Mercurial and Git history. They do not contain
checked-out source files, pip packages, or other task dependencies. Hardware WIMs are
not changed.

The Linux and Windows parallel alpha workflows resolve the latest autoland
decision once per run. Only configs with `experimental.gecko_cache_seed: true`
seed its paired Hg and Git revisions. The flag is off by default. The next run
resolves the latest decision again. The seed stays fixed after image creation;
tasks fetch later changes normally.

Windows provisioning uses `Initialize-GeckoCacheSeed` in the existing
`Bootstrap` module; it calls Hg and Git directly, not a Python seed helper. Linux provisioning uses
`scripts/linux/common/preload-gecko-hg.sh` and `gecko_hg.py` in the same directory.
The Python code builds seed directories and moves them into place before the Linux worker starts.
The two platforms have separate implementations.

Hg uses `robustcheckout --noupdate` from the selected autoland revision.
It uses `--upstream https://hg.mozilla.org/mozilla-unified`, as real tasks do.
This includes upstream history during image creation, so the first task does
not need to fetch history that is absent from an autoland-only seed.
It requests stream clones, uses server-advertised clone bundles, and retries
transport failures through robustcheckout. It then fetches any missing changes.
The `--revision` option selects the target after the initial clone; it does not
restrict the clone or disable bundles. No source files are checked out.
The builder checks the store format and selected revision before it writes the
seed marker. It accepts zstd stores and does not force recompression to zlib.
It does not run a separate full-history `hg verify`. A failed build does not
register caches or publish an image. A failed direct-store build can leave an
incomplete store; use a fresh image build rather than that partial store.

Source tarballs, such as GitHub source archives, do not contain `.hg` or `.git`
history. They cannot replace these seeds without changes to task checkouts.

This PR leaves image Puppet pins unchanged. Before enabling the Windows seed,
validate that the selected Puppet revision provides the C: cache paths and
permissions described below. The seed builder fails if those checks do not pass.

For a direct Packer build, set `gecko_hg_seed_revision` to the full 40-character
`GECKO_HEAD_REV` from an Hg task in the latest autoland decision task graph:
`gecko.v2.autoland.latest.taskgraph.decision`. The source is fixed to
`https://hg.mozilla.org/integration/autoland`. An empty revision disables the
seed. Do not use `tip` or a moving branch name.

For example, add these arguments to the normal Packer build command:

```text
-var 'gecko_hg_seed_revision=<full-autoland-Hg-revision>'
-var 'gecko_git_seed_revision=<full-autoland-Git-revision>'
-var 'gecko_seed_decision=<autoland-decision-task-id>'
```

The cache level comes from the image name: `trusted-` selects level 3;
other images use level 1. Azure uses the configuration name, and GCP uses the
Packer source name. No separate seed-level input is needed.
Do not enable this WIP on a pool with a different cache layout or trust domain.
Omit the Git revision to retain the Hg-only trial. Git seeding requires the
paired Hg revision. It is not enabled in hardware WIMs or other build workflows.

## Windows cloud images

Puppet must set `HG_CACHE=C:\hg-cache` and give task users inherited write
access to `C:\hg-shared`. The seed script fails if that setting differs. It runs
after Puppet as SYSTEM, with Worker Runner stopped.

On x64, the image builder writes the Hg store directly under
`C:\hg-shared\<root-changeset>`. This is the pool that Gecko's `run-task` already
uses. Hg needs no directory-cache state file or copy to D:. The builder requires
SYSTEM and creates the store under Puppet's configured parent directory. Files
inherit task-user access when they are created. The private temporary checkout
is outside the pool and is removed after seeding. The builder checks ownership
and inherited access on sample files; it does not run recursive ACL or owner repairs.

On ARM64, Gecko uses `build/hg-store` inside a Generic Worker checkout cache.
The PowerShell builder prepares the seed in a temporary directory, copies
independent full and sparse caches under `C:\caches`, and writes initial state
to `C:\worker-runner\directory-caches.json`. It removes the temporary seed
after image creation. These use
`gecko-level-<level>-checkouts` and `gecko-level-<level>-checkouts-sparse`.
Generic Worker grants task-user access when it mounts each cache.

The ARM64 image also registers `relops-level-3-checkouts-sparse` for the
existing OS integration startup test. The builder clones history once, then
copies that seed into three independent cache directories during image creation.
There are no extra network clones and no cache copies at worker startup.
The directories do not share hardlinks or junctions: a task can change or purge
one cache without changing the others. This costs one extra Hg store on the
image disk. Windows x64 needs no RelOps copy because both task types use
`C:\hg-shared` directly.

## Git caches

The builder fetches Git history once from
`https://github.com/mozilla-firefox/firefox` at the paired autoland Git commit.
It creates a depth-1 seed through local Git transport. Both seeds contain a
normal `.git` directory without checked-out files, alternates, or hardlinked
objects. Each task can fetch a newer revision with `run-task-git`.
Both seeds must resolve `HEAD` to the selected commit. Fetch failures stop the
build. The builder does not run a separate full-history `git fsck --full`.

Git uses independent `gecko-level-<level>-checkouts-git` and
`gecko-level-<level>-checkouts-git-shallow` caches. The repository is at `src`
inside Windows caches and `gecko` inside Linux caches. The RelOps startup test
uses Hg, so no RelOps Git caches are created. Both Windows architectures use
directory-cache state for Git; neither
uses `C:\hg-shared` for Git. Hg and Git registrations are written together.

Linux moves two extra seed directories, full and shallow, into the caches
directory. D2G seeds have UID/GID 1000 and use the pinned decision's
`run-task-git` cache initializer. Their `-v3-<hash>` suffix follows Gecko's
decision repository type: an Hg decision hashes `run-task-hg`, even for Git
tasks. A Git decision hashes `run-task-git`. External Docker cache suffixes
remain outside this trial.

Allow space for both Git seed formats and their runtime copies in addition to
Hg. Full Gecko disk use and Linux restore time have not been measured in a
cloud build. Do not infer a speed gain from these local checks. The existing
`benchmark.py` measures Hg only; Git reuse is covered by `test_git_seed.py`
locally and still needs a fresh-image task test.

Use the C: pool configuration from fxci-config. These changes do not convert
older D: pools or change tasksDir, cachesDir, or downloadsDir.

## Linux images

Linux seeds one Gecko full-checkout cache. D2G images also register
`relops-level-3-checkouts-sparse-hg58-v3-<run-task-hash>` for the OS integration
startup test. No checkout option is needed
for the Hg trial. Autoland decision `W2W5EeeBSJu1jaEnKQkzAw` has 3,435 Linux
Docker-style Hg task definitions using the full cache and 453 using the sparse
cache. These are task definitions, not measured task volume or cache-hit rates.
Both checkout types work; the Gecko sparse cache is not preloaded.
Other cache names continue to use the normal cold-checkout path.

The image keeps each seed as a plain directory under
`/usr/local/share/gecko-hg-seed` and `/usr/local/share/gecko-git-seed`
(mode 0700, outside `/home`). Hg stores and Git packs are already compressed,
so the image does not archive them again. Before Worker Runner starts, its
ExecStartPre hook renames each seed directory into
`/home/generic-worker/caches` and writes initial state to
`/directory-caches.json`. The service has no WorkingDirectory and starts in
`/`; this hook does not change that.

This is for pools without a local SSD (noscratch), where the seed and the
caches directory are on the boot disk, so the move takes no time. If a seed is
on a different filesystem from the caches directory, the hook registers no
caches and tasks clone normally. Copying from the boot disk to an SSD costs
more than it saves.

D2G seeds have UID/GID 1000 from the image build. D2G registers one Hg seed as
two caches, Gecko full and RelOps sparse. The RelOps cache gets a full `cp -a`
copy on the boot disk, because Hg writes revlogs in place and the two caches
must not share files. Native Linux moves one store. If an install is
interrupted, a cache directory that is already in place is kept on the next
boot.

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

The automatic OS integration suite is not a cache benchmark. Its replication
step changes cache names to `relops-level-3-*` in the deployed main-branch hook.
The Windows ARM64 and Linux D2G seeds include the matching RelOps sparse cache.
The run-task hash must match on Linux. A passing startup test alone does not
prove seed reuse or a speed gain; check the seed marker and checkout log.
Most OS tests use downloaded test artifacts and do not request a Gecko checkout.

Use a targeted task from the latest autoland decision for the cache trial.
Keep its Gecko cache name, Hg `run-task` command, cache mount, and container
UID/GID. Select a Linux full-checkout task for the local-SSD alpha pool. Its
cache level and run-task hash must match the image manifest. Do not rename a
level-3 cache to level 1 just to make this check pass. Windows x64 uses
`C:\hg-shared`; ARM64 needs an exact directory-cache name match.

Each baked Hg store has a `.hg/worker-image-seed` file with its revision. Run
the following wrapper inside the task, after the cache mount, around its actual
Hg `run-task` checkout command. End that command with a no-op task command so
the measurement covers checkout, not a build or test suite:

```sh
uv run scripts/cache-seeds/benchmark.py \
  --store <mounted-sharebase/root-node> --checkout <checkout-path> \
  --seed-revision <revision-from-image-manifest> -- <run-task-command>
```

Use the Python already in the task if uv is not present. Do not install uv at
worker startup. Supply this script as a task artifact, outside the Gecko
checkout that the command creates.

The wrapper fails if the checkout is already present, the image seed is absent
or has the wrong revision, the command replaces the seed marker, or the checkout
does not share the specified store. It prints an `HG_CACHE_BENCHMARK` JSON record
with checkout time and the reuse result. It does not remove or reset a cache.
For the unseeded baseline, omit `--seed-revision`; the store and checkout must
both be absent. Use the same command, source revision, machine type, and disk
layout for both runs.

This wrapper does not prove that the worker is fresh or verify its cloud image
ID. Record the actual image ID and worker history separately. Use the first
cache task on a new worker. Also record VM-request-to-task-completion time and
Linux seed install time; checkout time alone excludes it.
The targeted task submission and these cloud checks are still required before
the draft can be merged. The regular OS suite remains a separate correctness
check, not a substitute for this measurement.

The seed stores history only. `robustcheckout` creates the task checkout and
fetches missing changes. No absolute `.hg/sharedpath` from the image build is
stored in the seed. Full and sparse caches do not share mutable store files.

The installer never replaces an existing worker state file. Reimage to test a
new seed. Image creation fails if cache state is already present. Cache records
retain the seed's build time so later purge requests still apply. On POSIX,
the host cache parent is private (0700); tasks can access only mounted caches.
An interrupted install that leaves cache directories without state
fails closed; reimage that worker. Reserve disk space for two Linux D2G Hg runtime
stores (one on native Linux, three on Windows ARM64), the Git stores, image seeds,
task checkouts, and subsequent changes.

Local checks:

```sh
uv run --python 3.10 --with mercurial==6.2.1 scripts/cache-seeds/test_gecko_hg.py
uv run --python 3.11 --with mercurial==6.9 scripts/cache-seeds/test_gecko_hg.py
uv run scripts/cache-seeds/test_benchmark.py
uv run --with pyyaml scripts/cache-seeds/test_git_seed.py
# Test updates with the decision artifact's actual Git helper:
RUN_TASK_GIT=/path/to/run-task-git uv run scripts/cache-seeds/test_git_seed.py
# On Linux as root, test with Gecko's pinned helpers too:
RUN_TASK=/path/to/run-task ROBUSTCHECKOUT=/path/to/robustcheckout.py \
  uv run scripts/cache-seeds/test_gecko_hg.py
```

Linux uses the Python already installed in the image. Windows uses PowerShell
and the installed Hg and Git executables. Startup does not install uv or fetch
a Python environment.

The Hg check downloads a fixed test version of robustcheckout unless
`ROBUSTCHECKOUT` points to a local copy. Image builds instead obtain the helper
from the autoland revision selected for that build.
CI checks upstream Hg 6.2.1 and 6.9, the executable versions configured by
Puppet for Windows ARM64 and x64. It also checks the `ubuntu-latest` runner's
Mercurial apt package, which includes distribution patches. Do not replace that check with
the unpatched upstream 6.7.2 package. These checks do not replace tests of the
Windows executables or the Mercurial package in each task container.
The Linux integration check uses a small local Hg repository to check run-task
cache requirements, UID/GID, reuse, later revisions, and live state preservation.
Windows image builds run the seed checks in `tests/win/task_storage.tests.ps1`
after provisioning. With seeding enabled, Pester checks the selected Hg and Git
revisions, checkout-cache registrations, shallow Git layout, and x64 task-user
ACLs. The seed checks are skipped when seeding is disabled. Fresh-worker task
reuse and startup cost still need separate validation.

For the Linux trial, use a pool with local SSD and confirm its exact Hg cache
name, run-task hash, and UID/GID before building. Compare an unseeded image and
a seeded image with the same task and machine type. Record VM-request-to-first-
task-completion time, restore time, checkout time, later task times, and peak
disk use. Do not infer a speed gain from worker readiness alone.

Keep the PR in draft until cloud images pass validation. Use the latest
autoland decision task as the baseline. All tier-1 tasks must pass before a
production rollout. A new-image-only tier-1 regression blocks deployment.
