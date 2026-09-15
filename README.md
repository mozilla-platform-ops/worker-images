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
| Firefox CI Windows | Windows 10, Windows 11 24H2/25H2, Windows Server 2022, x64 and arm64 tester/builder variants | Azure |
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
7. `.github/workflows/` handles cloud authentication and build matrices, then
   calls `.github/actions/packer-build` for config validation, Packer setup,
   plugin caching, and the existing WorkerImages helpers. Workflows retain
   replication, artifact publishing, and integration validation.
8. `taskcluster/` defines the Taskcluster task graph used by integration tests.

## Repository Layout

| Path | Purpose |
| --- | --- |
| `.github/workflows/` | GitHub Actions workflows for Azure, GCP, AWS, pre-commit, and OS integration jobs |
| `.github/actions/packer-build/` | Shared composite build action for all eight Packer build workflows |
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

Builds are normally run with GitHub Actions workflow dispatch. The workflows
check the actor against `.github/relsre.json` or `.github/tceng.json` before
they build.

| Workflow | File | Use |
| --- | --- | --- |
| `FXCI - Azure Prod Parallel Images` | `sig-FXCI-parallel-build.yml` | Full Windows production build. Builds untrusted production configs and trusted Azure configs in one matrix. |
| `FXCI - Azure Alpha Parallel Images` | `sig-FXCI-nontrusted-parallel-build-alpha.yml` | Windows alpha builds from `images.alpha` in `windows_production_defaults.yaml`. |
| `FXCI - Azure` | `sig-nontrusted.yml` | One-off untrusted Windows Azure build. |
| `FXCI - Azure - Trusted` | `sig-trusted.yml` | One-off trusted Windows Azure build. Do not use this in addition to the prod parallel workflow for a full rollout. |
| `FXCI - GCP Alpha Parallel Images` | `gcp-fxci-parallel-alpha.yml` | Builds all Firefox CI Ubuntu alpha images in GCP, or one image with the optional `config` input. |
| `FXCI - GCP Prod Parallel Images` | `gcp-deploy-parallel.yml` | Promotes all Firefox CI Ubuntu alpha images into date-stamped production GCP images, or one image with the optional `config` input. |
| `OS Integration Tests - FXCI` | `os-integration.yml` | Triggers Taskcluster integration tests against a built image. |
| TC Engineering workflows | `nonsig-tceng-azure.yml`, `gcp-tceng.yml`, `aws-tceng.yml` | Builds images owned by Taskcluster Engineering. |

## Windows Image Model

Windows Firefox CI images are Azure Compute Gallery images. Each config under
`config/` defines the marketplace source image, gallery name, gallery image
name, gallery version, VM size, ronin_puppet role, and Pester tests.

`config/windows_production_defaults.yaml` provides shared Windows defaults:

- OpenVox and Git versions used during bootstrap.
- The default `ronin_puppet` organization, repository, branch, and
  `deploymentId`.
- The production and alpha config lists used by the parallel Azure workflows.

Image configs override a recursive merge of the defaults. Omit inherited keys;
there is no `"default"` sentinel. Arrays are replaced, not concatenated, and
explicit false/empty values override defaults. Most production configs inherit
the ronin_puppet pin by omitting `vm.tags.deploymentId`.
The gallery version is per config in
`sharedimage.image_version`; bump the configs you actually intend to rebuild.
`azure.locations` lists replica targets, excluding the build region; `[]` means
build-region only. CI compares each gallery with active fxci-config pool consumers
using that repository's variant and image-alias resolver, including pool overrides.

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
images live in `fxci-production-level3-workers`. Production rollouts update
the matching image paths in `fxci-config`.

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
2. Bump the image config in this repo. For Windows, update the relevant
   `sharedimage.image_version` values and the default `deploymentId` if the
   ronin_puppet pin changed.
3. Run the appropriate parallel build workflow.
4. Verify the published images, release notes, and integration results. For
   Windows production parallel builds, **all `Replicate` jobs must succeed** and
   each image must have a matching `deployment-ready-*` artifact before changing
   `fxci-config`. A successful Packer job alone means only the build-region image
   exists. See [build changes and validation](docs/packer-build-changes.md).
5. Open an `fxci-config` PR that points worker pools at the new versions or
   GCP image paths.
6. Trigger `/taskcluster integration` on that PR.
7. After merge, watch fresh worker-manager events and pool health to confirm
   new workers boot the expected image.

Alpha workflows keep waiting for OS integration results by default. Set
`wait_for_results: false` only to submit tests and collect their task-group links;
a green submission job is not evidence that those tests passed.

Azure builds use Azure CLI OIDC login for the pre-Packer SKU check, and Packer
performs its own OIDC exchange. The SKU catalogue check cannot reserve capacity
or guarantee quota. Dispatching a feature branch still requires a matching
federated identity credential in Azure; arrange an approved subject with the
identity owner before running branch builds.

## Shared Packer Action

After checkout and cloud authentication on an Ubuntu runner, call
`./.github/actions/packer-build` with `builder` (`azure`, `gcp`, `azure-tceng`,
`gcp-tceng`, or `aws-tceng`) and `config`. TC Engineering Azure/AWS also require
`location`; `taskcluster-ref` is optional. Only FXCI Azure production supports
`defer-replication: 'true'`.

Pass credentials through the calling step's `env`, as the existing workflows do.
The action preserves Azure's `sharedimageversion` environment value and replication
manifest for downstream artifact steps. Authorization, OIDC permissions, secret
selection, and deployment gates belong to the caller. Cloud-specific HCL templates
remain separate; the action reuses their existing PowerShell entrypoints.

## Local Development

Most image builds require cloud credentials and should be run through GitHub
Actions. Local work is still useful for formatting, static validation, and
Taskcluster taskgraph tests.

```bash
pre-commit run --all-files
python3 -m unittest discover -s ci -p 'test_*.py' -v
pwsh -NoProfile -File ci/test-build-helpers.ps1
bash tests/linux/test_generate_sbom.sh
# Requires PSScriptAnalyzer 1.25.0.
pwsh -NoProfile -File ci/check-powershell.ps1
# Uses fxci-config's locked dependencies; no cloud API calls.
uv run --frozen --no-dev --project ../fxci-config python ci/check-azure-regions.py ../fxci-config

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
uv run ci/run-os-integration.py win11_64_24h2_alpha
uv run ci/run-os-integration.py win11_64_24h2_alpha --no-wait
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
