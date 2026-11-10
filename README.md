# Worker Images

This repository builds and validates virtual machine images for Mozilla
Taskcluster worker pools. It uses Packer for image creation, YAML files for
per-image configuration, GitHub Actions for dispatch and publishing, and
Taskcluster jobs for integration validation.

The repository started as a Windows Azure image builder. It now covers Firefox
CI Windows images in Azure Compute Gallery, Ubuntu 24.04 images in GCP, and a
separate set of Taskcluster Engineering image builds.

## What It Builds

| Area | Images | Cloud |
| --- | --- | --- |
| Firefox CI Windows | Windows 10, Windows 11 25H2, Windows Server 2022, x64 and arm64 tester/builder variants | Azure |
| Firefox CI Linux | Ubuntu 24.04 headless, arm64 headless, and GUI/Wayland images, including trusted level-3 variants | GCP |
| Taskcluster Engineering | Generic worker images for Azure, GCP, and AWS experiments and migrations | Azure, GCP, AWS |

Production Firefox CI rollouts do not finish in this repository. This repo
publishes images and release notes. The worker-pool references that actually
make CI boot a new image are managed in `mozilla-releng/fxci-config`.

## How The Pieces Fit

1. `config/*.yaml` describes an image: base OS, cloud project or gallery,
   machine type, image name, tags, and image-specific tests.
2. `bin/WorkerImages/` reads that config, applies defaults where relevant, sets
   Packer variables, and starts Packer.
3. `azure.pkr.hcl`, `gcp.pkr.hcl`, and `packer/tceng-*.pkr.hcl` define the VM
   build steps.
4. `scripts/` provisions the guest OS. Windows images use a PowerShell
   Bootstrap module; Linux images use shell scripts grouped by distro and image
   family.
5. `tests/` runs image-level checks during the Packer build.
6. `sboms/` stores generated release notes and software bill of materials for
   Windows image builds.
7. `.github/workflows/` builds images, uploads release-note artifacts, and
   starts integration validation.
8. `taskcluster/` defines the Taskcluster task graph used by integration tests.

## Repository Layout

| Path | Purpose |
| --- | --- |
| `.github/workflows/` | GitHub Actions workflows for Azure, GCP, AWS, pre-commit, and OS integration jobs |
| `bin/WorkerImages/` | PowerShell module used by workflows to translate YAML config into Packer environment variables |
| `ci/` | Workflow helper scripts for matrix generation, authorization checks, image builds, and Taskcluster integration triggers |
| `config/` | Firefox CI image definitions plus `windows_production_defaults.yaml` |
| `config/tceng/` | Taskcluster Engineering image definitions |
| `packer/` | Packer templates for Taskcluster Engineering images |
| `scripts/linux/` | Linux provisioning scripts for Firefox CI and Taskcluster Engineering images |
| `scripts/windows/` | Windows Bootstrap module and Taskcluster Engineering provisioning scripts |
| `tests/linux/` | Linux image validation scripts |
| `tests/win/` | Windows Pester tests selected by each Windows image config |
| `taskcluster/` | Taskgraph code for image integration tests |
| `provisioners/` | Internal non-cloud and hardware-imaging work; not part of normal cloud image rollouts |

## Common Build Workflows

Builds are normally run with GitHub Actions workflow dispatch. Each workflow
checks the actor against `.github/relops.json` and any additional workflow
allowlists before it builds.

| Workflow | File | Use |
| --- | --- | --- |
| `FXCI - Production Parallel Images` | `fxci-production-parallel.yml` | RelOps-only entry point for Windows, Linux, or both. A single UTC build date is shared across selected platforms. |
| `FXCI - Azure Prod Parallel Images` | `sig-FXCI-parallel-build.yml` | Full Windows production build. Builds untrusted production configs and trusted Azure configs in one matrix. |
| `FXCI - Azure Alpha Parallel Images` | `sig-FXCI-nontrusted-parallel-build-alpha.yml` | Windows alpha builds from `images.alpha` in `windows_production_defaults.yaml`. |
| `FXCI - Azure Image Build` | `sig-azure.yml` | One-off trusted or untrusted Windows Azure build. Optional OS integration runs for untrusted images; use the parallel workflow for a full rollout. |
| `FXCI - GCP Alpha Images` | `gcp-fxci-parallel-alpha.yml` | Builds one or all Firefox CI Ubuntu alpha images; scans successful untrusted builds and runs integration for all-mode or an opted-in single image. |
| `FXCI - GCP Prod Parallel Images` | `gcp-deploy-parallel.yml` | Promotes all or one selected Firefox CI Ubuntu alpha image into a date-stamped production GCP image. |
| `OS Integration Tests - FXCI` | `os-integration.yml` | Triggers Taskcluster integration tests against a built image. |
| TC Engineering workflows | `nonsig-tceng-azure.yml`, `gcp-tceng.yml`, `aws-tceng.yml` | Builds images owned by Taskcluster Engineering. |

## Windows Image Model

Windows Firefox CI images are Azure Compute Gallery images. Each config under
`config/` defines the marketplace source image, gallery name, gallery image
name, gallery version, VM size, ronin_puppet role, and Pester tests.

`config/windows_production_defaults.yaml` provides shared Windows defaults:

- OpenVox, Puppet, and Git versions used during bootstrap.
- The default `ronin_puppet` organization, repository, branch, and
  `deploymentId`.
- The production and alpha config lists used by the parallel Azure workflows.

Most production configs inherit the default ronin_puppet pin by setting
`vm.tags.deploymentId: "default"`. Production Windows gallery versions are
generated from the UTC build date as `yyyy.MM.dd` (for example
`2026.11.04`). Set `sharedimage.image_version` only to pin a version; alpha
configs keep their explicit versions. A second build of the same image on the
same day needs a different version.

During the build, the Windows Bootstrap module installs prerequisites, clones
ronin_puppet at the configured branch and commit, applies Puppet, runs the
config-selected Pester tests, generates release notes, and syspreps the image.

## Linux Image Model

Firefox CI Linux images are Ubuntu 24.04 GCP images. Alpha builds create or
replace images whose names end in `-alpha`. Production workflows copy those
alpha images into date-stamped production image names such as:

```text
gw-fxci-gcp-l1-2404-amd64-headless-googlecompute-2026-06-23
gw-fxci-gcp-l3-2404-amd64-headless-googlecompute-2026-06-23
```

Level-1 images live in the `taskcluster-imaging` project. Trusted level-3
images live in `fxci-production-level3-workers`. Production image names use the
shared UTC deployment date in `yyyy-MM-dd` format. Before replacing an existing
same-day image, the workflow checks `fxci-config/main` and stops if it references
the image. Production rollouts update the matching image paths in `fxci-config`.

Set `vm.preloadCaches: true` to preload the Gecko Git seed. Set
`vm.preloadDockerImages` to a list of Gecko Docker image names to preload for
that worker pool. The AMD64 alpha configs select images from sampled pool
usage; the ARM64 configs preload Gecko only until their Docker image use is
measured. The list defaults to empty.

`New-GCPWorkerImage` resolves the current Autoland image task IDs before
Packer starts. The image build stores each archive in Generic Worker’s download
cache, loads its Docker layers, and writes Generic Worker’s file and D2G cache
state into the image. The file cache uses the exact artifact task ID; the D2G
cache uses the archive SHA256. A newer artifact misses safely and follows the
normal download or image-load path. Duplicate task IDs in one image list are
downloaded once. The seed build fails if it leaves less than 1 GiB free in its
32 GiB filesystem.

All five Linux alpha configs enable `preloadCaches`. Direct Packer builds also
need `-var 'preloadCacheManifest=/path/to/inputs.json'` with
`preloadCaches=true`.

## Development image builds (RelOps only)

Run **Image generation dev** (`image-dev.yml`) from `main`. Select the cloud
**provider**, enter the worker-images **branch** to test, and provide a
non-trusted root-level alpha **config** name without `.yaml`, for example
`win11-64-25h2-alpha` or `gw-fxci-gcp-l1-2404-headless-alpha`.

The workflow checks the actor and rerun actor against `.github/relops.json`
from `main`, resolves the branch to one commit, validates its config using
trusted code, and checks out that commit for the entire build. The selected
revision supplies the helpers, config/defaults, templates, scripts, and tests.
Branch names can contain slashes. No YAML `dev` setting is needed.

Only alpha Azure galleries/images/worker pools and the non-trusted GCP
`taskcluster-imaging` project are allowed. Trusted keys, config subdirectories,
non-alpha destinations, missing branches, and symbolic links fail before cloud
login. Azure builds retry up to ten times using the same commit.

Release notes are uploaded as `dev-release-notes-<config>` artifacts, marked
`DEV BUILD` with the branch and commit. They are not committed to `main`.
Normal build and promotion workflows are unchanged. Development builds still
write to the selected alpha image destination; coordinating simultaneous builds
or isolating their output images is follow-up work in RELOPS-2631. Authorized
branch code runs with the non-trusted build credentials and is not sandboxed.

Local checks (requires PowerShell 7.3+ and `powershell-yaml`):

```bash
pwsh -NoProfile -File ci/test-image-dev.ps1
```

## Validation

There are three layers of validation:

- Packer build tests run inside the image before publishing.
- Some workflows automatically trigger Taskcluster OS integration tests through
  `.github/workflows/os-integration.yml` and `ci/run-os-integration.py`.
- Production rollouts should also be validated from the `fxci-config` PR using
  `/taskcluster integration`, because that tests the worker-pool config that
  will actually ship.

For Firefox CI images, tier-1 test health is the release bar. If a new image
makes tier-1 red or materially more intermittent, it is not ready for
production pools.

## Production Rollout Shape

The short version for Firefox CI production rollouts:

1. Land any image content changes first. Windows content usually comes from
   `ronin_puppet`; Linux content usually comes from this repository's Linux
   scripts and config.
2. Bump the image config in this repo. For Windows, update the default
   `deploymentId` if the ronin_puppet pin changed. Gallery versions are set
   automatically from the UTC build date.
3. Run `FXCI - Production Parallel Images` and select Windows, Linux, or both.
   The workflow passes one UTC date to both providers: Azure formats gallery
   versions as `yyyy.MM.dd`; GCP uses `yyyy-MM-dd` in image names.
4. Verify the published images, release notes, and integration results.
5. After all selected builds and promotions succeed, the unified workflow opens
   an `fxci-config` PR with the exact image references. The PR includes image
   tables, Windows-specific `ronin_puppet` commits, per-image SBOM links, and build
   provenance. It updates Windows 10, Windows 11 25H2, Server 2022, and Ubuntu
   production entries; it leaves Server 2025 and alpha entries unchanged.

   For older, separate production runs, use the helper manually:

   ```powershell
   Import-Module ./bin/WorkerImages/WorkerImages.psm1
   New-FxciConfigPullRequest -AzureRunId <run-id> -GcpRunId <run-id>
   ```

   Pass one run ID for a single platform. For a combined unified run, pass the
   same ID to both parameters. `-WhatIf -Verbose` previews the change. The helper
   always targets `mozilla-releng/fxci-config`.

   Production run artifacts are retained for 90 days, so manual PR regeneration
   must happen within that window. PR SBOM links point to durable copies in `sboms/`.

   The workflow needs the `PULL_REQUESTOR_APP_ID` and `PULL_REQUESTOR_KEY`
   repository secrets. Install that GitHub App on `mozilla-releng/fxci-config`
   with Contents and Pull requests write access. The workflow uses a short-lived
   app token to create the PR and the worker-images `GITHUB_TOKEN` to read run
   artifacts.
6. Trigger `/taskcluster integration` on that PR.
7. After merge, watch fresh worker-manager events and pool health to confirm
   new workers boot the expected image.

## Local Development

Most image builds require cloud credentials and should be run through GitHub
Actions. Local work is still useful for formatting, static validation, and
Taskcluster taskgraph tests.

```bash
pre-commit run --all-files

packer init azure.pkr.hcl
packer validate azure.pkr.hcl

packer init gcp.pkr.hcl
packer validate gcp.pkr.hcl

cd taskcluster
pytest test/
```

To trigger OS integration tests from a local shell, set
`TASKCLUSTER_CLIENT_ID` and `TASKCLUSTER_ACCESS_TOKEN`, then run:

```bash
uv run ci/run-os-integration.py win11_64_25h2_alpha
uv run ci/run-os-integration.py win11_64_25h2_alpha --no-wait
```

## Terms

| Term | Meaning |
| --- | --- |
| FXCI | Firefox CI |
| Taskcluster | Mozilla's CI platform for Firefox and related projects |
| Worker image | A VM image booted by a Taskcluster worker pool |
| ronin_puppet | The Puppet repository used to configure Windows Firefox CI images |
| Azure Compute Gallery / SIG | Azure image gallery where versioned Windows images are published |
| SBOM | Software bill of materials generated from the built Windows image |
| Trusted image | A higher-trust image variant with access to chain-of-trust signing material |
