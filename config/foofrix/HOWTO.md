# FooFrix image HOWTO

Use this guide to change a Perf image, add an image, or publish a new version.
See [README.md](README.md) for architecture, access, and installer details.

## Change an existing image

1. Edit the selected file in `config/foofrix/`.
   - Change versions and source revisions under `software`.
   - Add supported installer or extraction actions under `build_steps`.
   - Add a check to `tests/win/foofrix-base.tests.ps1` for new software.
2. For a staged installer, upload a new immutable installer set and update
   `installers.json` with its URL, size, and SHA-256. Do not overwrite an
   existing installer release.
3. Set `azure.image_version` to a new, unused `major.minor.patch` version.
4. Validate the configuration:

   ```bash
   packer init packer/foofrix-azure.pkr.hcl
   python3 ci/test-foofrix-config.py
   pre-commit run --files config/foofrix/IMAGE.yaml
   ```

FooFrix application source is installed when a VM starts. Source-only FooFrix
changes do not require a new base image.

### Add software

For an MSI, EXE, or ZIP, prefer configuration over new PowerShell:

1. Stage the file and add its URL, size, and SHA-256 to `installers.json`.
2. Add its version or filename under `software` in each affected image config.
3. Add an `install` or `extract` entry to that config's `build_steps`.
4. Add a command or file check to `tests/win/foofrix-base.tests.ps1`.

For Cargo, npm, or source-built tools, pin the version or revision in the image
config and install it in `prebake-tools.ps1` or `prebake-payload.ps1`. Install
for all users under `C:\FooFrix`; image scripts run as Windows SYSTEM, not as the
eventual Perf user.

### Add PowerShell

Put image-build scripts in `scripts/windows/foofrix/`. Packer uploads that whole
directory, but a new script does not run automatically. Invoke it from the
matching fixed stage:

- `windows-base.ps1` for base installation before the first restart.
- `prebake-tools.ps1` for compiler-dependent tools after that restart.
- `prebake-payload.ps1` for source checkouts, application builds, and caches.

Use `$ErrorActionPreference = 'Stop'` and strict mode. Check `$LASTEXITCODE`
after native commands, or use the existing `Invoke-BuildCommand` helper. Do not
ignore failures, log secrets, perform runtime login, or reboot inside a script;
Packer owns restarts. Add a matching post-build check and include every changed
script in the focused pre-commit command.

## Add another image

RelOps can add image galleries and definitions to the Performance Engineering
Azure subscription. Ask RelOps to create them, or open a PR against
[`terraform/azure_foofrix`](https://github.com/mozilla-platform-ops/relops_infra_as_code/tree/master/terraform/azure_foofrix)
and ask RelOps to review and apply it.

Follow the existing infrastructure pattern:

1. Create a dedicated Compute Gallery and image definition with matching names.
2. Grant `sp-foofrix-image-build` Contributor on the gallery.
3. Export the gallery and image-definition IDs.
4. Have RelOps apply the Terraform before the first image build.

Then, in this repository:

1. Copy the closest config in `config/foofrix/` and set its Marketplace source,
   `azure.gallery`, `azure.image_definition`, and initial image version.
2. Add the config name to the choices in
   [FooFrix Azure Images](../../.github/workflows/foofrix-azure.yml).
3. Extend `ci/test-foofrix-config.py` to check the new SKU, gallery, and image
   definition.

The config names must match resources already applied by RelOps.

## Build and publish

1. Merge the reviewed worker-images and infrastructure changes.
2. In GitHub Actions, run **FooFrix Azure Images** and select the config.
3. Wait for validation, authorization, image creation, and gallery publication.
4. Download `foofrix-manifest.json` from the workflow artifacts. It identifies
   the published gallery image version for Perf's VM provisioner.

The workflow never replaces an existing gallery version. If a build fails, keep
its temporary resources for diagnosis and ask RelOps to remove them afterward.
