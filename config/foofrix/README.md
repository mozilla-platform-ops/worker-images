# FooFrix Windows images

RELOPS-2570 adds a standalone image build path for Perf. The initial config is
Windows 11 25H2 x64 with Git, Node.js 24, Python, C++ Build Tools, 7-Zip,
Rust/Cargo, Samply, Searchfox CLI, and Google Cloud CLI. The payload stage adds
MozillaBuild, a full Firefox source build, FooFrix, run-speedometer, profiler-cli,
Codex, the statistical comparison environment, and Playwright Firefox downloads. This is a base image draft;
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

Supply a directory prefix such as `windows/releases/2026-09-14` in the
private `artifacts` container. Actions downloads matching files with the dedicated
OIDC identity and Packer copies them to `C:\FooFrix\artifacts`, preserving their
blob paths. These files remain in the image. Only select source and binaries
intended for image distribution; runtime credentials are retrieved separately from GCP Secret Manager.
The selected prefix must contain `foofrix.bundle`, a self-contained Git bundle of
reviewed FooFrix source. From a full, authenticated FooFrix checkout, create it with:

```bash
git bundle create ../foofrix.bundle HEAD
```

Upload that file into the selected prefix using your existing blob access.
A Git bundle contains committed source/history, not your checkout's credentials,
Git configuration, untracked files, or installed dependencies. Review the selected
commit and ensure its tracked history contains no secrets before distribution.
Submodules are fetched at the revisions recorded by that commit. The current
perfcompare submodule is public; a future private submodule needs separate staging.
Actions checks for this bundle before starting Packer and stages a copy at
`C:\FooFrix\artifacts\foofrix.bundle`. No GitHub token is sent to the guest.
The bundle's selected source executes during the trusted image build; restrict
artifact write access and review its commit as carefully as the image recipe.

The workflow uploads `foofrix-manifest.json`, containing the published artifact
identifier, to the run. Perf's provisioner selects the gallery image version and
owns VM creation, networking, disks, runtime identity attachment, and deletion.

VM provisioning from the GCP Linux launcher and its GCP Secret Manager integration
are tracked in [FooFrix PR #1](https://github.com/dpalmeiro/foofrix/pull/1).

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
SYSTEM profile, not the account Perf later uses. User login, API keys, and starting FooFrix belong to the separately agreed runtime setup.
Packer handles the restart and image generalization after the recipe completes.

To add more complex steps, provide RelOps the tool name, version, artifact path,
silent install command (if known), expected installed location, and a command
that proves it works. The base recipe is deliberately short so those additions
can be reviewed with Perf.

## Prebaked application and browser payload

`prebake-payload.ps1` runs after the toolchain restart. It installs locked npm
dependencies and compiles TypeScript directly, avoiding upstream setup's Unix
`chmod`. It installs profiler-cli and its WASM file, initializes benchmark and
perfcompare submodules, and downloads each project's matching Playwright Firefox.
Public checkouts are pinned in the recipe. The supplied FooFrix commit and public
source revisions are recorded in `C:\FooFrix\source-manifest.json`; global npm
versions are recorded in `C:\FooFrix\npm-tools.json`.

| Payload | Shared location |
| --- | --- |
| FooFrix checkout and installed dependencies | `C:\FooFrix\src\foofrix` |
| Firefox checkout, object files and symbols | `C:\FooFrix\src\firefox` |
| Firefox bootstrap tools and mach environments | `C:\FooFrix\mozbuild` |
| Benchmark runner and Speedometer assets | `C:\FooFrix\tools\run-speedometer` |
| Playwright browsers | `C:\FooFrix\playwright` |
| Node CLI launchers | `C:\FooFrix\npm` |

The Firefox recipe uses MozillaBuild and native Python to run `mach bootstrap`
and a full optimized build with JS shell, retaining `obj-opt` and PDBs. It is
not an artifact build. The build VM is now 16 vCPUs with a 512 GiB OS disk to
accommodate source and build products. Image capture and disk costs will increase;
startup savings must be measured on a candidate VM. The Actions job retains its
six-hour limit; a timeout requires measuring the failing stage before resizing.

Keep these paths and machine environment variables when provisioning workers.
The runtime account needs modify access to its source/build/cache directories.
Do not relocate Python venvs or Firefox object files; their paths can be embedded.
Public clones are shallow, so jobs needing older history must fetch it. A revision
or toolchain change can invalidate the baseline build and require recompilation.
The baked Firefox remote uses native Git; Hg/try support remains separate work.

Post-build checks launch the cached Playwright Firefox for both projects, import
Python comparison dependencies, check CLI entry points, and take a headless
screenshot with the compiled Firefox. They do not establish GPU performance,
Windows profiling compatibility, or a working end-to-end FooFrix job.
MozillaBuild currently uses the vendor's latest installer, and Python/npm global
packages can resolve newer versions on rebuild; this is not a reproducible image.

See [Mozilla's Windows build instructions](https://firefox-source-docs.mozilla.org/setup/windows_build.html)
and [native mach invocation](https://firefox-source-docs.mozilla.org/mach/windows-usage-outside-mozillabuild.html).

## Remaining runtime work

- Validate the prebaked payload in an Azure candidate and adapt the harness
  runtime for Windows process invocation, paths, and worker lifecycle.
- Validate the required Chromium patches and profiling support on Windows; the
  current FooFrix source-image scripts target Linux/GCE.
- Agree on GPU model/driver and display-session requirements with Perf.
- Configure runtime secret retrieval and Google credentials for both `gcloud`
  and SDK access to `foofrix-findings`; runtime secrets are not image contents.
- Boot a candidate, build Firefox, run the agreed benchmark/profile smoke test,
  and verify the long-running workload before marking the image ready for use.

The build checks tool versions from the Packer account (separate from SYSTEM),
compiles and runs a small Rust program to exercise MSVC linking, and checks for
absence of Taskcluster services. It does not yet validate browser profiling.

Rust lives in `C:\FooFrix\cargo` and `C:\FooFrix\rustup`, exposed through machine
environment variables. Google Cloud CLI is installed for all users without login.
The runtime account needs write access to the Rust directories if jobs update
Rust or install Cargo tools; account creation and permissions remain runtime work.
Samply follows FooFrix's current `main` selection; `C:\FooFrix\cargo-tools.txt`
records resolved Cargo versions and the Git revision. These moving inputs mean
rebuilding an image version later is not guaranteed to produce identical tools.

Installation references: [Rust shared locations](https://rust-lang.github.io/rustup/installation/)
and [Google unattended installer](https://docs.cloud.google.com/sdk/docs/downloads-interactive).
