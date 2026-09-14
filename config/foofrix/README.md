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

## Editing the image without PowerShell experience

Start with `scripts/windows/foofrix/windows-base.ps1`. It is the image's recipe:
each uncommented line runs in order. Lines starting with `#` are comments or
disabled examples. RelOps maintains the error handling in `bootstrap-helpers.ps1`.
You normally only need to add or change recipe lines and their checks.

| Need | Recipe line |
| --- | --- |
| Install a Chocolatey package | `Install-BuildPackage -Name 'git'` |
| Pin a package version | `Install-BuildPackage -Name 'nodejs' -Version '24.13.0'` |
| Install a private MSI | `Install-BuildInstaller -Path 'C:\FooFrix\artifacts\tools.msi'` |
| Install a private EXE | `Install-BuildInstaller -Path 'C:\FooFrix\artifacts\setup.exe' -Arguments '/quiet /norestart'` |
| Unpack a ZIP | `Expand-BuildArchive -Path 'C:\FooFrix\artifacts\chromium.zip' -Destination 'C:\FooFrix\chromium'` |

Use the actual Chocolatey package name/version or uploaded file path. EXE silent
switches depend on the installer: check its documentation or ask RelOps. MSI
installs automatically use quiet mode and defer restart to Packer. A missing file
or failed installer stops the build; do not ignore it or replace it with a success
message. ZIPs should contain the directory layout you want at the destination.

For example, to include a Chromium ZIP:

1. In Azure Portal, open the FooFrix storage account, then **Containers → artifacts**.
   Upload the ZIP as `windows/releases/example/chromium.zip` using your team access.
2. In the recipe, uncomment the `$release` and `Expand-BuildArchive` example lines,
   adjusting `example` to the actual release directory.
3. Add this check to `tests/win/foofrix-base.tests.ps1`, adjusted to the ZIP layout:

   ```powershell
   if (-not (Test-Path 'C:\FooFrix\chromium\chrome.exe' -PathType Leaf)) {
       throw 'Chromium executable is missing'
   }
   ```

4. Commit the recipe/check changes on your reviewed branch. Run **FooFrix Azure
   Images** with `artifact_prefix` set to `windows/releases/example` and a new
   gallery version. The environment's allowed-branch/approval rules still apply.
5. Check the Actions build log and manifest. Verify the resulting browser in a
   candidate VM before using it for real jobs; a file check does not validate GPU
   acceleration or profiling.

These are image-build steps, not commands to run on your laptop. They execute as
Windows SYSTEM. Install tools for all users and use shared paths such as
`C:\FooFrix`; installers targeting the current user's profile would populate the
SYSTEM profile, not the account Perf later uses. User login, Rust user-profile
setup, API keys, and starting FooFrix belong to the separately agreed runtime setup.
Packer handles the restart and image generalization after the recipe completes.

To add more complex steps, provide RelOps the tool name, version, artifact path,
silent install command (if known), expected installed location, and a command
that proves it works. The base recipe is deliberately short so those additions
can be reviewed with Perf.

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
