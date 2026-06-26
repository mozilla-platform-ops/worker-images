# AGENTS.md

This file gives AI coding agents the repository-specific context needed to work
in `mozilla-platform-ops/worker-images`.

## What This Repository Does

This repository builds virtual machine images for Mozilla Taskcluster workers.
It uses Packer, YAML configuration, GitHub Actions, and Taskcluster integration
tests. The main image families are:

- Firefox CI Windows images in Azure Compute Gallery.
- Firefox CI Ubuntu 24.04 images in GCP.
- Taskcluster Engineering images in Azure, GCP, and AWS.

Production Firefox CI rollout is split across repositories. This repo publishes
images and release notes. `mozilla-releng/fxci-config` controls which images
worker-manager actually boots.

## Architecture

### Build Pipeline

1. Config YAML files under `config/` define image inputs. Windows configs can
   inherit values from `config/windows_production_defaults.yaml`.
2. Packer templates define cloud builders and provisioning steps:
   `azure.pkr.hcl`, `gcp.pkr.hcl`, and `packer/tceng-*.pkr.hcl`.
3. The PowerShell module in `bin/WorkerImages/` reads config, sets `PKR_VAR_*`
   variables, and invokes Packer.
4. GitHub Actions workflows in `.github/workflows/` dispatch builds and
   validation. Helper scripts in `ci/` handle matrix generation, authorization,
   wrapper build commands, and Taskcluster integration triggering.
5. Build-time tests run inside images from `tests/win/` and `tests/linux/`.
6. Taskcluster integration tests are defined under `taskcluster/` and triggered
   through `ci/run-os-integration.py`.

### Key Workflows

- `sig-FXCI-parallel-build.yml`: full Windows production build. Builds
  untrusted production configs from `images.production` plus trusted Azure
  configs discovered from `config/trusted-*.yaml`.
- `sig-FXCI-nontrusted-parallel-build-alpha.yml`: Windows alpha build matrix
  from `images.alpha`.
- `sig-nontrusted.yml`: one-off untrusted Windows Azure build.
- `sig-trusted.yml`: one-off trusted Windows Azure build.
- `gcp-fxci-parallel-alpha.yml`: Firefox CI Ubuntu alpha image builds.
- `gcp-deploy-parallel.yml`: Firefox CI Ubuntu production promotion from alpha
  images to date-stamped production images.
- `gcp-fxci.yml`: one-off Firefox CI Ubuntu alpha image build.
- `gcp-deploy.yml`: one-off Firefox CI Ubuntu production promotion.
- `os-integration.yml`: reusable and manually dispatched Taskcluster
  integration trigger.
- `nonsig-tceng-azure.yml`, `gcp-tceng.yml`, `aws-tceng.yml`: Taskcluster
  Engineering image workflows.

### Provisioning

Windows provisioning lives in `scripts/windows/CustomFunctions/Bootstrap/`.
The Bootstrap module installs prerequisites, clones ronin_puppet, runs Puppet,
applies local image checks, emits release notes, and prepares the image for
generalization.

Linux provisioning lives in `scripts/linux/`. Shared setup is in
`scripts/linux/common/`; image-family-specific scripts live under the Ubuntu
2404 directories.

Taskcluster Engineering provisioning is split between `scripts/windows/tceng/`
and `scripts/linux/tceng/`, with config in `config/tceng/`.

## Commands

Use these commands for local validation:

```bash
pre-commit run --all-files

packer init azure.pkr.hcl
packer validate azure.pkr.hcl

packer init gcp.pkr.hcl
packer validate gcp.pkr.hcl

cd taskcluster
pytest test/
```

To trigger integration tests locally:

```bash
# Requires TASKCLUSTER_CLIENT_ID and TASKCLUSTER_ACCESS_TOKEN.
uv run ci/run-os-integration.py win11_64_24h2_alpha
uv run ci/run-os-integration.py win11_64_24h2_alpha --no-wait
```

## Windows Firefox CI Images

Windows builds use `New-AzSharedWorkerImage` in
`bin/WorkerImages/Public/New-AzSharedWorkerImage.ps1`.

The function:

1. Reads `config/<name>.yaml`.
2. Merges inherited values from `config/windows_production_defaults.yaml`.
3. Sets Packer variables such as gallery name, image name, gallery version,
   VM size, ronin_puppet source, and deployment ID.
4. Runs `packer init azure.pkr.hcl`.
5. Runs `packer build --only azure-arm.sig azure.pkr.hcl`, with `-force` for
   alpha, beta, and next-style images.

Windows production configs usually inherit:

- `vm.puppet_version`
- `vm.git_version`
- `vm.openvox_version`
- `vm.tags.sourceOrganization`
- `vm.tags.sourceRepository`
- `vm.tags.sourceBranch`
- `vm.tags.deploymentId`

The Azure Compute Gallery version is per config in
`sharedimage.image_version`. Do not assume one default image version covers all
Windows configs.

## Ronin Puppet Pinning

Windows image content is mostly provided by `ronin_puppet`. These config fields
control what gets cloned and applied:

```yaml
vm:
  tags:
    sourceOrganization: mozilla-platform-ops
    sourceRepository: ronin_puppet
    sourceBranch: master
    deploymentId: "82415f4"
```

`Set-AzRoninRepo` clones the configured branch. If `deploymentId` is not `NA`,
it checks out that exact commit before `Start-AzRoninPuppet` applies Puppet.

For production rollouts, the deployment ID should be a commit on
`ronin_puppet` `master`. Alpha configs may point at feature branches, but do
not change alpha branch pins casually; those are often being used for active
testing.

## Linux Firefox CI Images

Linux builds use `New-GCPWorkerImage` in
`bin/WorkerImages/Public/New-GCPWorkerImage.ps1`.

The alpha workflow builds GCP images whose config names and image names end in
`-alpha`. The production workflow promotes those alpha images into date-stamped
GCP image names. Level-1 images use the `taskcluster-imaging` project. Trusted
level-3 images use `fxci-production-level3-workers`.

When updating production Linux worker pools in `fxci-config`, use the full GCP
image path emitted by the production promotion job.

## Testing And Validation

- Windows image tests are Pester tests in `tests/win/`; each config selects
  test files with its `tests:` list.
- Linux image tests are in `tests/linux/` and include shell checks plus Pester
  checks through PowerShell on Linux.
- Taskcluster integration tests are defined by `taskcluster/kinds/` and
  `taskcluster/worker_images_taskgraph/`.
- `.cron.yml` defines `run-integration-tests` as a hook-only Taskcluster
  decision job.

For Firefox CI images, tier-1 test health is the production bar. If a new image
makes tier-1 red or materially more intermittent, the image is not ready for
production rollout.

## Production Deployment Notes

Windows production rollout shape:

1. Update `config/windows_production_defaults.yaml` if the ronin_puppet
   deployment ID or shared tool versions changed.
2. Bump `sharedimage.image_version` in every Windows config that should be
   rebuilt, including trusted configs when they are in scope.
3. Dispatch `FXCI - Azure Prod Parallel Images`.
4. Verify each published gallery version and generated SBOM.
5. Use `fxci-config` to update worker-pool image versions and deployment IDs.
6. Trigger `/taskcluster integration` on the `fxci-config` PR.

Linux production rollout shape:

1. Build alpha images with `FXCI - GCP Alpha Parallel Images` when content
   changed.
2. Promote with `FXCI - GCP Prod Parallel Images`.
3. Update the corresponding `fxci-config` GCP image paths.
4. Trigger `/taskcluster integration` on the `fxci-config` PR.

Do not dispatch one-off trusted Windows builds in addition to the Windows prod
parallel workflow for a full rollout. The prod parallel workflow already builds
trusted Azure production configs.

## Editing Guidance

- Preserve unrelated local changes. This repo is often used during active image
  investigation.
- Use `rg` for search.
- Prefer editing shared workflow behavior in `ci/` helper scripts instead of
  copying inline PowerShell across workflows.
- Prefer `ci/check-authorized-user.ps1` for RelSRE workflow authorization.
- Keep image config changes scoped. Bumping a Windows production deployment ID
  usually also requires bumping the relevant per-config
  `sharedimage.image_version` values.
- Do not edit generated SBOM files by hand unless the task is explicitly about
  correcting release-note artifacts.
- Run `pre-commit run --all-files` after documentation, workflow, Packer, or
  whitespace-sensitive edits when practical.

## Terms

- FXCI: Firefox CI.
- TC: Taskcluster.
- Worker image: VM image booted by a Taskcluster worker pool.
- ronin_puppet: Puppet repository used to configure Windows Firefox CI images.
- SIG: Azure Shared Image Gallery, now Azure Compute Gallery.
- SBOM: Software bill of materials generated from a built image.
- Trusted image: Image variant with access to chain-of-trust signing material.
