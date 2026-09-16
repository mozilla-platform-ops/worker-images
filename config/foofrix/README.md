# FooFrix Windows images

RELOPS-2570 adds a standalone image build path for Perf. The initial config is
Windows 11 24H2 x64 with Git, Node.js 24, Python, C++ Build Tools, 7-Zip,
Rust/Cargo, Samply, Searchfox CLI, and Google Cloud CLI. The payload stage adds
MozillaBuild, a full Firefox source build, FooFrix, run-speedometer, profiler-cli,
Codex, the statistical comparison environment, and Playwright Firefox downloads. This is a base image draft;
it is not yet a validated Firefox/Chromium build or FooFrix runtime image.

Perf owns the config in this directory and `scripts/windows/foofrix/`. RelOps
maintains the shared build infrastructure. Builds publish versions into the
isolated FooFrix gallery; they do not update FXCI or TCEng images or worker pools.

## Azure and GitHub prerequisites

The infrastructure is tracked by RELOPS-2548 and relops_infra_as_code PR #339.
Terraform must create the gallery and the `win11_64_24h2` image definition
(Windows, x64, generalized, Hyper-V V2) before the first build. Confirm that
definition's security/disk settings match the selected Marketplace source.

Configure the GitHub environment `foofrix-image-build` with these variables:

| Variable | Value |
| --- | --- |
| `AZURE_CLIENT_ID_FOOFRIX_IMAGES` | Dedicated image-build application client ID |
| `AZURE_IDENTITY_ID_FOOFRIX_IMAGES` | Terraform `image_build_identity_id` output (full resource ID) |
| `AZURE_SUBSCRIPTION_ID_FOOFRIX` | Dedicated FooFrix subscription ID |
| `AZURE_STORAGE_ACCOUNT_FOOFRIX` | FooFrix storage account name |

The workflow reuses the existing repository secret `AZURE_TENANT_ID` for the
Mozilla tenant ID.

The build application's federated credential must trust issuer
`https://token.actions.githubusercontent.com`, audience `api://AzureADTokenExchange`,
and subject `repo:mozilla-platform-ops/worker-images:environment:foofrix-image-build`.
Restrict the environment's deployment branches to reviewed branches and configure
its approval rules before enabling builds. The workflow also checks the actor
against `.github/foofrix.json` and `.github/relsre.json`.

The build identity needs Contributor on the existing `rg-foofrix-image-build`
resource group and the `foofrix` gallery, Blob Data Reader on `artifacts`, and
Managed Identity Operator on `id-foofrix-image-build`, matching PR #339. Packer
creates temporary resources inside that group and derives its location from the
group. It must not create or delete the group itself. Failed builds can leave
resources there; inspect and remove only that build's leftovers.
The build managed identity is attached to the temporary VM. Artifacts currently
download in Actions and arrive through Packer, so guest blob authentication is
not used; the identity is available if that download strategy changes. Build
credentials must remain separate from the VM-provisioning identity and FXCI/TCEng
build applications. No Azure password is required by this workflow.

## Build and use

Dispatch **FooFrix Azure Images**, selecting `win11-24h2` and a new numeric
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

## Staged Windows installers

Actions downloads base installers from the private `artifacts` container in
`safoofrixaad679e2`. `config/foofrix/installers.json` records the versioned blob
prefix, original vendor URLs, sizes, and SHA-256 hashes. Actions verifies every
listed file before Packer starts and copies them to `C:\FooFrix\artifacts\installers`.
This installer prefix is independent of the source bundle's `artifact_prefix`.

The recipe no longer uses Chocolatey or downloads initial installers from vendors.
It installs Git, Node.js, Python, 7-Zip, and MozillaBuild from staged installers,
and extracts Google Cloud CLI's self-contained ZIP (including Python).
The staged Visual Studio Build Tools bootstrapper still downloads its C++ workload
and recommended components from Microsoft. The staged rustup bootstrapper still
downloads Rust 1.98.1. Git, Cargo, npm, Playwright, and Firefox bootstrap also need
internet access during the later payload stages. No offline C++ layout is required.

To update the base tools:

1. Download replacement files from their official vendor URLs. Verify published
   checksums/signatures where available and record the downloaded SHA-256 values.
2. Upload the complete installer set to a **new** versioned prefix using Azure
   login, without overwriting an existing release:

   ```bash
   az storage blob upload-batch --auth-mode login \
     --account-name safoofrixaad679e2 --destination artifacts \
     --destination-path windows/installers/NEW-RELEASE \
     --source ./installers --overwrite false
   ```

3. Update `installers.json` and the corresponding filenames/arguments in
   `windows-base.ps1` together. Review that change before building.

The manifest pins bytes, including the C++ and rustup bootstrappers; it does not
pin the additional packages those bootstrappers download. See Microsoft's
[Build Tools command-line options](https://learn.microsoft.com/en-us/visualstudio/install/use-command-line-parameters-to-install-visual-studio)
and Google's [versioned archives](https://docs.cloud.google.com/sdk/docs/downloads-versioned-archives).

## Editing the image without PowerShell experience

Start with `scripts/windows/foofrix/windows-base.ps1`. It is the image's recipe:
each uncommented line runs in order. Lines starting with `#` are comments or
disabled examples. RelOps maintains the error handling in `bootstrap-helpers.ps1`.
You normally only need to add or change recipe lines and their checks.

| Need | Recipe line |
| --- | --- |
| Install a private MSI | `Install-BuildInstaller -Path 'C:\FooFrix\artifacts\tools.msi'` |
| Install a private EXE | `Install-BuildInstaller -Path 'C:\FooFrix\artifacts\setup.exe' -Arguments '/quiet /norestart'` |
| Unpack a ZIP | `Expand-BuildArchive -Path 'C:\FooFrix\artifacts\chromium.zip' -Destination 'C:\FooFrix\chromium'` |

Use the uploaded installer filename from `installers.json` or your artifact path. EXE silent
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
Base installer files are pinned by SHA-256 in `installers.json`. C++ components,
Cargo/npm packages, and Firefox bootstrap downloads can still change between
builds; this is not a fully offline or reproducible image.

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
