# OS Integration Workflow Notes

## Overview
- `.github/workflows/os-integration.yml` is now reusable and can run from both manual dispatch and post-build automation.
- Azure nontrusted image builds trigger integration tests right after the `packer` job, in parallel with SBOM processing.

## Triggers
- **Manual:** `workflow_dispatch` with `config` (required) and optional `image_name` override.
- **Post-build:** `sig-nontrusted.yml` and `sig-FXCI-nontrusted-deploy-image.yml` call the workflow after `packer` completes.

## Image Name Resolution
- If `image_name` is provided, it is used directly.
- Otherwise the workflow reads `config/<config>.yaml` and uses `sharedimage.image_name`.

## Taskcluster Hook
- The workflow triggers the Taskcluster hook `project-releng/cron-task-mozilla-platform-ops-worker-images/run-integration-tests`.
- Payload format is `{"images": ["<image_name>"]}` to target the built image.

## Manual Usage
1. Open GitHub Actions → **OS Integration Tests - FXCI**.
2. Choose a `config` and optionally supply `image_name`.
3. Run the workflow and follow the Taskcluster task group URL in logs.

## Future Enhancements
- Add multi-image support (comma-separated or JSON list) for batch runs.
