# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Does

Builds virtual machine images for Mozilla's Taskcluster CI workers using Packer, with configuration driven by YAML files and builds executed via GitHub Actions. Supports Windows (Azure) and Linux/Ubuntu (GCP) images. Also has Taskcluster-based integration tests that replicate Gecko and Translations CI tasks against new images.

## Architecture

### Build Pipeline

1. **Config YAML** (`config/*.yaml`) defines each image: base OS, Azure/GCP settings, VM size, tags, and which Pester tests to run. Per-image configs inherit from `config/windows_production_defaults.yaml` (default values for shared image version, puppet version, git version, deployment ID, etc.).
2. **Packer HCL templates** (`azure.pkr.hcl` for Azure/Windows, `gcp.pkr.hcl` for GCP/Linux, `packer/tceng-*.pkr.hcl` for TC Engineering pools) define the build steps.
3. **PowerShell module** (`bin/WorkerImages/`) reads config YAML, merges with defaults, sets `PKR_VAR_*` environment variables, and invokes `packer build`. Key entry point: `New-AzSharedWorkerImage` for Azure SIG builds.
4. **GitHub Actions** (`.github/workflows/`) orchestrate builds. Workflow helper scripts in `ci/` handle matrix generation, auth checks, and Taskcluster integration triggers. Key workflows:
   - `sig-FXCI-parallel-build.yml` — Production Azure image builds (trusted + untrusted)
   - `sig-FXCI-nontrusted-parallel-build-alpha.yml` — Alpha Azure image builds
   - `gcp-fxci-parallel-alpha.yml` / `gcp-fxci.yml` — GCP Linux image builds
   - `os-integration.yml` — Triggers Taskcluster integration tests after builds
   - `sig-trusted.yml` / `nonsig-trusted.yml` — Single-image trusted builds (with Key Vault COT keys)

### Provisioning

- **Windows**: `scripts/windows/CustomFunctions/Bootstrap/` is a PowerShell module (`Bootstrap.psm1`) dot-sourced during Packer builds. Functions in `Public/` handle: installing prerequisites, cloning ronin_puppet, running Puppet, disabling services, running Pester tests, and generating SBOMs.
- **Linux**: `scripts/linux/` contains shell scripts organized by distro/arch (e.g., `ubuntu-2404-amd64-gui/fxci/`, `common/`). Scripts install packages, configure Docker, set up GPU drivers, Papertrail, etc.

### Testing

- **Windows** (`tests/win/*.tests.ps1`): Pester tests run inside the VM during Packer build. Each config YAML lists which test files to run in its `tests:` array.
- **Linux** (`tests/linux/`): Shell-based tests and Pester tests (via PowerShell on Linux). `run_all_tests.sh` executes all `.tests.ps1` files found in `/workerimages/tests/`.
- **Integration tests**: Taskcluster `integration-test` kind (`taskcluster/kinds/integration-test/kind.yml`) replicates Gecko CI tasks against worker images. Triggered via `ci/run-os-integration.py`.

### Taskcluster Taskgraph

`taskcluster/worker_images_taskgraph/` contains custom taskgraph transforms and parameters. The `integration-test` kind uses `mozilla_taskgraph.transforms.replicate` to clone tasks from mozilla-central's os-integration decision. Cron config in `.cron.yml` defines hook-triggered integration test runs.

### SBOMs

`sboms/` contains auto-generated markdown files documenting installed software for each image version. Generated during packer build by `Set-ReleaseNotes` in the Bootstrap module.

## Commands

### Pre-commit / Linting

```bash
# Pre-commit hooks: trailing whitespace + packer fmt
pre-commit run --all-files

# Format Packer HCL files
packer fmt azure.pkr.hcl
packer fmt gcp.pkr.hcl
```

### Packer (local validation only — builds run in GitHub Actions)

```bash
packer init azure.pkr.hcl
packer validate azure.pkr.hcl

packer init gcp.pkr.hcl
packer validate gcp.pkr.hcl
```

### OS Integration Tests (local trigger)

```bash
# Requires TASKCLUSTER_CLIENT_ID and TASKCLUSTER_ACCESS_TOKEN
uv run ci/run-os-integration.py win11_64_24h2_alpha
uv run ci/run-os-integration.py win11_64_24h2_alpha --no-wait
```

### Taskcluster Taskgraph Tests

```bash
cd taskcluster
pytest test/
```

## How to Build an Image

Builds are triggered via GitHub Actions workflow dispatch (not locally). The general flow:

1. **Alpha builds** (testing): Trigger `sig-FXCI-nontrusted-parallel-build-alpha.yml` (Azure/Windows) or `gcp-fxci-parallel-alpha.yml` (GCP/Linux). These read `windows_production_defaults.yaml` `images.alpha` list. Alpha builds always use `packer build -force` (overwrites existing image).
2. **Production builds**: Trigger `sig-FXCI-parallel-build.yml` (Azure) or `gcp-fxci.yml` (GCP). The Azure workflow builds the untrusted configs from `images.production` plus any trusted Azure configs found in `config/`. Production builds create versioned images in Azure Shared Image Gallery.
3. **Single-image trusted builds**: `sig-trusted.yml` / `nonsig-trusted.yml` remain available for one-off trusted images that need COT signing keys (chain-of-trust for Taskcluster).

### Azure/Windows Build Flow

The workflow calls `New-AzSharedWorkerImage` (`bin/WorkerImages/Public/New-AzSharedWorkerImage.ps1`) which:
1. Reads `config/<image-name>.yaml` and merges with `config/windows_production_defaults.yaml`
2. Sets all `PKR_VAR_*` environment variables from the merged config
3. Runs `packer init azure.pkr.hcl` then `packer build --only azure-arm.sig azure.pkr.hcl`

Packer then: copies Bootstrap module to VM, clones ronin_puppet, runs Puppet, runs Pester tests, generates SBOM, and syspreps.

### GCP/Linux Build Flow

The workflow calls `New-GCPWorkerImage` (`bin/WorkerImages/Public/New-GCPWorkerImage.ps1`) which:
1. Reads `config/<image-name>.yaml`
2. Sets `PKR_VAR_*` variables (project ID, image name, zone, taskcluster version, etc.)
3. Runs `packer init gcp.pkr.hcl` then `packer build --only googlecompute.<key> -force gcp.pkr.hcl`

## How Config YAML Controls Ronin Puppet

For Windows images, three fields in `config/*.yaml` under `vm.tags` control which ronin_puppet branch and commit the image is built from:

```yaml
vm:
  tags:
    sourceOrganization: mozilla-platform-ops   # GitHub org
    sourceRepository: ronin_puppet             # GitHub repo
    sourceBranch: master                       # Branch to clone (or a JIRA ticket branch like "RELOPS-2252")
    deploymentId: "96de7f5"                    # Git commit hash to checkout (or "NA" to use branch HEAD)
```

During the Packer build, `Set-AzRoninRepo` (`scripts/windows/CustomFunctions/Bootstrap/Public/Set-AzRoninRepo.ps1`):
1. Clones `https://github.com/{sourceOrganization}/{sourceRepository}` at branch `{sourceBranch}`
2. If `deploymentId` is not `"NA"`, checks out that specific commit
3. Then `Start-AzRoninPuppet` applies the Puppet manifests from that checkout

**To change which ronin_puppet branch an image uses**: Edit the `sourceBranch` value in the image's config YAML. For alpha images, this is typically set to a feature branch (e.g., `RELOPS-2252`). For production, it's set to `master` with a pinned `deploymentId`.

**Production defaults** (`config/windows_production_defaults.yaml`) set the shared defaults for `sourceOrganization`, `sourceRepository`, `sourceBranch`, and `deploymentId`. Per-image configs can override these, or use `"default"` to inherit.

## Production Deployment Process

A production deployment builds new versioned machine images and publishes them to Azure Shared Image Gallery, where Taskcluster worker pools pick them up. The full process:

### 1. Prepare the Config

Update `config/windows_production_defaults.yaml` with the values for this release:
- `sharedimage.image_version` — Bump the version (e.g., `1.2.0` to `1.3.0`). All production images that set `image_version: "default"` inherit this.
- `vm.tags.deploymentId` — Set to the ronin_puppet commit hash to pin.
- `vm.tags.sourceBranch` — Typically `master` for production.
- `vm.puppet_version`, `vm.git_version`, `vm.openvox_version` — Update tool versions as needed.

Per-image configs (`config/win11-64-24h2.yaml`, etc.) use `"default"` for most fields so they inherit from production defaults. Only override values that differ per image (VM size, base OS SKU, test lists, gallery names).

### 2. Build Production Images

Trigger `sig-FXCI-parallel-build.yml` via workflow dispatch. This:
1. Reads `images.production` from `windows_production_defaults.yaml` and auto-discovers trusted Azure configs in `config/` to build a matrix
2. Checks the user is in `.github/relsre.json`
3. Builds all production images in parallel via Packer into Azure Shared Image Gallery, using the trusted or untrusted Azure subscription per config
4. Each image is versioned (e.g., `win11_64_24h2` version `1.3.0`) and replicated to multiple Azure regions
5. Downloads the generated SBOM markdown from each build VM
6. Commits SBOMs to `sboms/` on main
7. Triggers OS integration tests for untrusted tester images (excluding `win2022` builders and `a64` builders)

### 3. Build Single Trusted Images

Trigger `sig-trusted.yml` for each trusted image (dropdown selection). Trusted images run in a separate Azure subscription with access to Key Vault for COT signing keys. The workflow builds one image at a time and commits its SBOM.

### 4. OS Integration Tests

After untrusted builds complete, `os-integration.yml` runs automatically for each tester image. It:
1. Resolves the `sharedimage.image_name` from the config YAML
2. Calls `ci/run-os-integration.py` which triggers a Taskcluster hook (`cron-task-mozilla-platform-ops-worker-images/run-integration-tests`)
3. The hook creates a decision task that replicates Gecko CI tests (source-test, startup-test, mochitest, web-platform-tests, etc.) against the new image
4. Polls until all tasks complete, then reports pass/fail with a GitHub Actions job summary

### 5. Worker Pool Rollout

After images are built and tested, the Taskcluster worker pool configuration (managed externally in `mozilla/community-tc-config` or `mozilla-releng/fxci-config`) must be updated to reference the new image version. This step happens outside this repository. The `sharedimage.gallery_name` and `sharedimage.image_name` in the config YAML correspond to the Azure Shared Image Gallery resources that worker pools reference.

### Version Bump Workflow

For a typical production release:
1. Update `config/windows_production_defaults.yaml` — bump `sharedimage.image_version`, update `deploymentId` to new ronin_puppet commit
2. Commit and push to main
3. Trigger the production build workflow
4. Wait for builds + integration tests to pass
5. Update worker pool configs externally to point to the new image version

## Key Conventions

- **Image naming**: `{os}-{arch}-{version}` with optional `-alpha`, `-beta`, `-next` suffixes. Alpha images use `-force` on packer build. Examples: `win11-64-24h2`, `win10-64-2009-alpha`, `win11-a64-24h2-builder`.
- **Config inheritance**: Per-image YAML values of `"default"` are overridden by `windows_production_defaults.yaml`. Non-default values in the image config take precedence.
- **Trusted vs untrusted**: Trusted builds (prefix `trusted-`) fetch COT signing keys from Azure Key Vault / GCP Secret Manager. Untrusted builds skip this.
- **Workflow authorization**: GHA workflows check `.github/relsre.json` for authorized users before building.
- **PowerShell modules follow dot-source pattern**: `*.psm1` files dot-source all `Public/*.ps1` and `Private/*.ps1` files, then export public functions.
- **Adding/removing images from builds**: Edit `config/windows_production_defaults.yaml` — the `images.production` and `images.alpha` lists control which configs are included in the GHA build matrix.
