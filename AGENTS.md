# AGENTS.md

## Project Overview

This repo builds Mozilla Taskcluster worker images with Packer, YAML config,
GitHub Actions, and Taskcluster integration tests.

- Firefox CI Windows images are built in Azure Compute Gallery.
- Firefox CI Ubuntu 24.04 images are built and promoted in GCP.
- Taskcluster Engineering image configs live under `config/tceng/`.

Read `README.md` for the human-facing architecture and rollout overview.

## Important Paths

- `config/`: Firefox CI image definitions; Windows defaults are in
  `config/windows_production_defaults.yaml`.
- `bin/WorkerImages/`: PowerShell helpers that start Packer builds.
- `ci/`: GitHub Actions helper scripts.
- `.github/workflows/`: image build and validation workflows.
- `scripts/`: Windows and Linux provisioning.
- `tests/`: image build-time checks.
- `taskcluster/`: integration-test taskgraph.
- `sboms/`: generated Windows release notes.

## Commands

Run the focused checks for the files you changed when possible:

```bash
pre-commit run --files <changed-files>
```

Useful local validation:

```bash
packer init azure.pkr.hcl
packer validate azure.pkr.hcl
packer init gcp.pkr.hcl
packer validate gcp.pkr.hcl
cd taskcluster
pytest test/
```

Taskcluster integration trigger:

```bash
# Requires TASKCLUSTER_CLIENT_ID and TASKCLUSTER_ACCESS_TOKEN.
uv run ci/run-os-integration.py <image-name>
uv run ci/run-os-integration.py <image-name> --no-wait
```

## Development Notes

- Use `rg` for searching.
- Preserve unrelated local changes; this repo is often used during active image
  investigation.
- Prefer shared scripts in `ci/` over copying inline workflow PowerShell.
- Prefer `ci/check-authorized-user.ps1` for RelSRE workflow authorization.
- Do not edit generated SBOM files unless the task is specifically about
  release-note artifacts.
- Keep image config changes scoped to the requested image family.

## Production Image Notes

- Windows production image content is usually pinned by
  `vm.tags.deploymentId` in `config/windows_production_defaults.yaml`.
- Windows Azure gallery versions are per config in `sharedimage.image_version`.
- Do not run one-off trusted Windows builds in addition to the Windows prod
  parallel workflow for a full rollout.
- Firefox CI production rollouts finish in `mozilla-releng/fxci-config`, not
  in this repo.
- Tier-1 Firefox CI health is the release bar. If a new image makes tier-1 red
  or materially more intermittent, it is not ready for production.
