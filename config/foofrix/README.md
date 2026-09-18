# FooFrix Windows images

RELOPS-2570 adds a standalone image build path for Perf. The initial config is
Windows 11 24H2 x64 with Git, Node.js 24, Python, C++ Build Tools, 7-Zip,
Rust/Cargo, Samply, Searchfox CLI, and Google Cloud CLI. The payload stage adds
MozillaBuild, a full Firefox source build, run-speedometer, profiler-cli, Codex,
and the benchmark runner's Playwright Firefox download. FooFrix source and its
project dependencies are installed during VM bootstrap. This is a base image draft;
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
The build managed identity is attached to the temporary VM. The VM downloads installers directly from Blob Storage using this identity.
Only scripts and configuration cross WinRM. Build
credentials must remain separate from the VM-provisioning identity and FXCI/TCEng
build applications. No Azure password is required by this workflow.

## Build and use

Set `azure.image_version` in `config/foofrix/win11-24h2.yaml` to a new numeric
`major.minor.patch` gallery version (initially `0.1.0`), then dispatch **FooFrix
Azure Images**, selecting `win11-24h2`. Bump the YAML version for each new image;
the workflow never forces replacement of an existing version.
`image.version: latest` selects the Marketplace source OS and is separate from
the destination gallery version. The Packer build size is independent of Perf's
eventual VM size.

The workflow needs only the image configuration. The build VM downloads the
staged installers described below; no FooFrix source bundle or source prefix is
required to build an image.

The workflow uploads `foofrix-manifest.json`, containing the published artifact
identifier, to the run. Perf's provisioner selects the gallery image version and
owns VM creation, networking, disks, runtime identity attachment, and deletion.

VM provisioning from the GCP Linux launcher and its GCP Secret Manager integration
are tracked in [FooFrix PR #1](https://github.com/dpalmeiro/foofrix/pull/1).
Its `create`/`bootstrap` commands install the reviewed FooFrix bundle as the
configured Windows user after boot, install its npm/Python/browser dependencies,
and preserve an existing checkout on reruns. Updating or editing FooFrix does not
require rebuilding the image. See that repository's `docs/azure-workers.md` for
bundle staging and bootstrap settings.

## Staged Windows installers

The build VM downloads base installers from the private `artifacts` container in
`safoofrixaad679e2`. `config/foofrix/installers.json` records the versioned blob
prefix, original vendor URLs, sizes, and SHA-256 hashes. The VM verifies every
listed file before installation and stores it in `C:\FooFrix\artifacts\installers`.
Downloads use the attached build identity, bounded retries, and SHA-256 checks.
This installer prefix is independent of the source bundle used at VM bootstrap.

The recipe no longer uses Chocolatey or downloads initial installers from vendors.
It installs Git, Node.js, Python, 7-Zip, and MozillaBuild from staged installers,
and extracts Google Cloud CLI's self-contained ZIP (including Python).
The staged Visual Studio Build Tools bootstrapper still downloads its C++ workload
and recommended components from Microsoft. The staged rustup bootstrapper still
downloads the Rust toolchain selected in the image YAML. Git, Cargo, npm, Playwright, and Firefox bootstrap also need
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

3. Update `installers.json` and the corresponding `software` settings in the
   image YAML together. Installer argument changes belong in `build_steps`.
   Review those changes before building.

The manifest pins bytes, including the C++ and rustup bootstrappers; it does not
pin the additional packages those bootstrappers download. See Microsoft's
[Build Tools command-line options](https://learn.microsoft.com/en-us/visualstudio/install/use-command-line-parameters-to-install-visual-studio)
and Google's [versioned archives](https://docs.cloud.google.com/sdk/docs/downloads-versioned-archives).

## Editing the image without PowerShell experience

Set versions and source revisions in the `software` section of
`config/foofrix/win11-24h2.yaml`. Packer passes that configuration to the guest as
`C:\FooFrix\image-config.json`, which the installation scripts and image checks read.
For example, `software.node` selects the Node installer version, `software.rust`
selects the Rust toolchain, and `software.firefox_revision` selects Firefox source.
`codex: latest`, `searchfox_cli: "*"`, and `samply_revision: main` retain the prior
moving selections; replace them with exact package versions/commit IDs to pin them.
The C++ and rustup bootstrapper filenames are selected here too; their exact bytes
are pinned by `installers.json`. C++ components still come from Microsoft's online
installer. Playwright and project dependencies follow their source lockfiles.

For staged software, changing a version also requires staging the corresponding
installer and updating its checksum in `installers.json`. That file is the artifact
lock/inventory, not an independent software-version setting. Bump
`azure.image_version` when publishing the resulting image.

Check the YAML wiring and version validation locally (Packer required, no Azure calls):

```bash
python3 ci/test-foofrix-config.py
```

For installation behavior, edit `build_steps` in the image YAML. Steps run in
order. RelOps maintains the allow-listed dispatcher and error handling in
`bootstrap-helpers.ps1`. Use `{name}` in an artifact or argument to insert the
matching value from `software` without executing PowerShell.

| Need | YAML step |
| --- | --- |
| Install a private MSI | `{ action: install, artifact: tools.msi }` |
| Install a private EXE | `{ action: install, artifact: setup.exe, arguments: /quiet /norestart }` |
| Unpack a ZIP | `{ action: extract, artifact: chromium.zip, destination: 'C:\FooFrix\chromium' }` |

Use an uploaded filename from `installers.json`; paths and arbitrary commands are
rejected. EXE silent
switches depend on the installer: check its documentation or ask RelOps. MSI
installs automatically use quiet mode and defer restart to Packer. A missing file
or failed installer stops the build; do not ignore it or replace it with a success
message. ZIPs should contain the directory layout you want at the destination.

To include another installer or archive in the image, add it to the next
installer release and `installers.json`, add a `build_steps` entry to the image
YAML, and add a matching check in
`tests/win/foofrix-base.tests.ps1`. Source bundles belong to VM bootstrap and
must not be added to the installer manifest.

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

`prebake-payload.ps1` installs the reusable public tools after the toolchain
restart. It compiles run-speedometer, initializes its benchmark submodule, caches
its Playwright Firefox, and installs profiler-cli, Codex, and the Firefox build.
Public source revisions are recorded in `C:\FooFrix\source-manifest.json`; global
npm versions are recorded in `C:\FooFrix\npm-tools.json`.

| Payload | Shared location |
| --- | --- |
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

Post-build checks launch run-speedometer's cached Playwright Firefox, check CLI
entry points, reject baked FooFrix source/bundles, and take a headless screenshot
with the compiled Firefox. FooFrix CLI, Python comparison dependencies, and its
matching browser are checked after VM bootstrap. They do not establish GPU performance,
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
Samply uses `software.samply_revision` (initially `main`); `C:\FooFrix\cargo-tools.txt`
records resolved Cargo versions and the Git revision. These moving inputs mean
rebuilding an image version later is not guaranteed to produce identical tools.

Installation references: [Rust shared locations](https://rust-lang.github.io/rustup/installation/)
and [Google unattended installer](https://docs.cloud.google.com/sdk/docs/downloads-interactive).

## Differences from the other Azure Windows builds

Compared with `packer/tceng-azure.pkr.hcl`, `azure.pkr.hcl`, and their workflows:

| Area | FooFrix | TCEng / production Windows |
| --- | --- | --- |
| Installer transfer | Guest downloads private blobs with its managed identity and verifies SHA-256; WinRM carries scripts/config only. | TCEng downloads packages in its bootstrap script; production uses Bootstrap/Puppet and guest downloads. |
| Provisioning | Standalone PowerShell recipes, staged installers, no Chocolatey; Firefox is compiled during image creation. | TCEng uses a bootstrap script including Chocolatey; production uses Ronin/Puppet roles. |
| Build resources | Dedicated existing resource group; its location determines the build region. | TCEng creates a temporary resource group from the requested location and deletes it asynchronously. |
| Image output | Explicit YAML gallery version and replication regions. | TCEng template creates managed images; production also supports gallery images and parallel builds. |
| Runtime | No Taskcluster services; editable FooFrix checkout is installed during VM bootstrap. | Taskcluster worker setup is part of the other images. |
| Verification and reporting | Tool, Rust/MSVC, and browser smoke checks; inventories stay inside the image and Actions publishes the Packer manifest. | Production runs Ronin/Pester tests and exports software release notes into its SBOM workflow. |

Follow-up gaps: FooFrix does not export its guest inventories or persistent guest
build logs to Actions. Some software selections still float (`latest`, `main`,
and online installer components), so the YAML alone is not a complete lockfile.
The six-hour job limit includes the full Firefox and Rust-tool builds; successful
end-to-end timing is still needed. These are separate from the installer-transfer fix.
