# FooFrix Windows images

RELOPS-2570 adds a standalone image build path for Perf. The initial config is
Windows 11 25H2 x64 with Git, Node.js 24, and Python. This is a base image draft;
it is not yet a validated Firefox/Chromium build or FooFrix runtime image.

Perf owns the config in this directory and `scripts/windows/foofrix/`. RelOps
maintains the shared build infrastructure. Builds publish versions into the
isolated FooFrix gallery; they do not update FXCI or TCEng images or worker pools.

## Azure and GitHub prerequisites

The infrastructure is tracked by RELOPS-2548 and relops_infra_as_code PR #339.
Terraform must create the gallery and the `foofrix_win11_25h2` image definition
(Windows, x64, generalized, Hyper-V V2) before the first build. Confirm that
definition's security/disk settings match the selected Marketplace source.

Configure the GitHub environment `foofrix-images` with these variables:

| Variable | Value |
| --- | --- |
| `AZURE_CLIENT_ID_FOOFRIX_IMAGES` | Dedicated image-build application client ID |
| `AZURE_TENANT_ID` | Mozilla tenant ID |
| `AZURE_SUBSCRIPTION_ID_FOOFRIX` | Dedicated FooFrix subscription ID |
| `AZURE_STORAGE_ACCOUNT_FOOFRIX` | FooFrix storage account name |

The build application's federated credential must trust issuer
`https://token.actions.githubusercontent.com`, audience `api://AzureADTokenExchange`,
and subject `repo:mozilla-platform-ops/worker-images:environment:foofrix-images`.
Restrict the environment's deployment branches to reviewed branches and configure
its approval rules before enabling builds. The workflow also checks the actor
against `.github/foofrix.json` and `.github/relsre.json`.

The build identity needs permissions in FooFrix to create/delete temporary Packer
resource groups and their VM/network/Key Vault resources, publish gallery versions,
and read the `artifacts` container. It must not reuse the VM-provisioning identity
or the FXCI/TCEng build applications. No Azure password is required by this workflow.

## Build and use

Dispatch **FooFrix Azure Images**, selecting `win11-25h2` and a new numeric
`major.minor.patch` gallery version. The workflow never forces replacement of an
existing version. The Packer build size is independent of Perf's eventual VM size.

Optionally supply a directory prefix such as `windows/releases/2026-09-14` in the
private `artifacts` container. Actions downloads matching files with the dedicated
OIDC identity and Packer copies them to `C:\FooFrix\artifacts`, preserving their
blob paths. These files remain in the image. Only select source and binaries
intended for image distribution; runtime credentials belong in Key Vault.
Add installation commands to the reviewed bootstrap script as contents are agreed.

The workflow uploads `foofrix-manifest.json`, containing the published artifact
identifier, to the run. Perf's provisioner selects the gallery image version and
owns VM creation, networking, disks, runtime identity attachment, and deletion.

## Remaining runtime work

- Agree on the Windows Firefox toolchain, Rust setup for the runtime user,
  MozillaBuild, and benchmark/profiling tools. Add those installation steps and checks.
- Validate the required Chromium patches and profiling support on Windows; the
  current FooFrix source-image scripts target Linux/GCE.
- Agree on GPU model/driver and display-session requirements with Perf.
- Configure runtime secret retrieval and Google credentials for both `gcloud`
  and SDK access to `foofrix-findings`; runtime secrets are not image contents.
- Boot a candidate, build Firefox, run the agreed benchmark/profile smoke test,
  and verify the long-running workload before marking the image ready for use.

The build currently checks base tools and absence of Taskcluster services only.
