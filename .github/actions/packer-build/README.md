# Packer build action

Runs `packer init`, `packer validate`, then `packer build`. The Packer template
selects the provider; the action has no Azure/GCP/AWS or worker-pool dispatcher.

| Input | Meaning |
| --- | --- |
| `template` | Required template file or directory relative to the checked-out workspace |
| `only` | Optional Packer build/source selector, passed to validation and build |
| `force` | Replace an existing image when `true`; defaults to `false` |

Check out the template repository and authenticate with the cloud before calling
this action. Supply template variables through `PKR_VAR_*`. The caller owns SDK
setup, image-config validation, artifacts, replication, and deployment readiness.

```yaml
- name: Build image
  uses: ./.github/actions/packer-build
  with:
    template: packer/tceng-aws.pkr.hcl
    force: 'true'
```

In this repository, the `Set-AWSWorkerImageVariables`,
`Set-AzWorkerImageVariables`, `Set-AzSharedWorkerImageVariables`, and
`Set-GCPWorkerImageVariables` PowerShell functions resolve image configs before
this step. They replace the former `New-*WorkerImage` functions: **preparation
no longer builds an image**. They set the current process environment and export
it through `GITHUB_ENV` when running in GitHub Actions. Local callers run Packer
explicitly after preparing variables.

Offline action checks: `pwsh -NoProfile -File ci/test-packer-action.ps1`.

The four FXCI Azure entrypoints delegate their repeated image-build job to
`.github/workflows/build-azure-image.yml`. That workflow checks RelSRE access and
config trust before Azure login, prepares variables, calls this generic action,
and uploads image artifacts. Entrypoints retain explicit credential selection,
matrices, region checks, publication, and integration/replication gates.
