# nuc-wim — Baked `install.wim` pipeline for NUC Windows CI workers

A Packer (**nested Hyper-V**) workflow that starts from **your own base
`install.wim`** (BYO, from the `nucwimfxci` `base/` blob), runs the ronin Puppet
*bake* (stable, expensive config), Sysprep generalizes, and captures a new golden
`install.wim`. No Azure marketplace or compute-gallery dependency.

Goal: move the ~30-min deploy-time AppX removal (and most of the ~36-min Puppet
run) into a pre-baked image, cutting NUC deploy time from ~63 min toward ~20–25 min.

The build runs on an **Azure VM** (nested-virtualization SKU) stood up by
`New-NucWimBuildVm.ps1`; the WIM build itself is Packer (`bin/NucWim/New-NucWim.ps1`).
Lives in worker-images at `provisioners/windows/nuc-wim/`.

> Constraint: nothing here pushes to `main`/`master`. The one ronin change (the
> `win116424h2hwbake` role) is authored on a feature branch in the `ronin_puppet`
> checkout.

## Pipeline

```
your base install.wim
  1. prepare-base-vhdx.ps1   apply WIM -> bootable VHDX (DISM /Apply-Image + bcdboot)
  2. packer build nuc-wim    Hyper-V boots VHDX
  3.   bake-bootstrap.ps1    install puppet/git, clone ronin, AppX (provisioned) removal,
                             WU/choco, puppet apply of the BAKE role
  4.   sysprep-generalize    scrub machine state + Sysprep /generalize /shutdown
  5.   capture-wim.ps1       mount generalized VHDX -> DISM /Capture-Image -> install.wim + SHA256
  6. publish                 copy install.wim to the MDT/WDS deployment share
  7. deploy                  existing PXE dance -> first-boot personalization + worker registration
```

## Layout

| Path | Purpose |
| --- | --- |
| `config/nuc-wim-defaults.yaml` | Shared defaults (storage, ronin, versions, VM size). Fields set to `"default"` in an image config resolve here. |
| `config/<image>.yaml` | **One file per WIM.** Base WIM, index, bake role, branch, versions. Adding a WIM = adding a file. |
| `New-NucWimBuildVm.ps1` | Provision the Azure nested-virt build host (managed identity + Hyper-V + tooling). |
| `scripts/bootstrap-build-host.ps1` | On-VM bootstrap (Hyper-V + Packer/ADK/azcopy/git), run by the provisioner. |
| `bin/NucWim/New-NucWim.ps1` | **Orchestrator.** `-Image <name>` runs prep → build → publish with per-image namespacing. |
| `nuc-wim.pkr.hcl` | Packer Hyper-V template (build + provision + capture) |
| `variables.pkr.hcl` | Input variable declarations |
| `example.pkrvars.hcl` | Reference only — the orchestrator generates the real var-file per build |
| `scripts/prepare-base-vhdx.ps1` | BYO WIM → bootable VHDX (Windows host, admin) |
| `scripts/bake-bootstrap.ps1` | Build-time bake (runs inside the VM via Packer) |
| `scripts/sysprep-generalize.ps1` | Scrub + Sysprep (runs inside the VM) |
| `scripts/capture-wim.ps1` | Capture WIM from generalized VHDX (Windows host, admin) |
| `scripts/download-wim.ps1` / `upload-wim.ps1` | Move WIMs to/from the private store (Entra auth) |
| `scripts/publish-wim.ps1` | Copy WIM to MDT share (Windows host) |
| `work/<image>/` | Per-image build artifacts (base WIM, VHDX, build dir, golden WIM) — gitignored |

Config style and tooling mirror **worker-images** (`config/*.yaml` + a `bin/` driver,
with the `"default"` → defaults-file resolution).

## Prerequisites (Windows host)

- Hyper-V enabled; `packer`, `az`, and `azcopy` on PATH; Windows ADK (DISM) available.
- Admin PowerShell; `powershell-yaml` module (auto-installed by the orchestrator); ~60–80 GB free disk.
- A base WIM uploaded to the `base/` container (e.g. `win11-24h2-base-install.wim`).
- Entra identity with Storage Blob Data access (a Relops member, or the uploader/downloader SP).
- For publish/deploy: write access to the MDT share + a canary NUC.

## Storage

Base and captured WIMs live in the **`nucwimfxci`** Azure Blob account, **Entra-only**
(open network, no account keys, no anonymous — access is gated purely by Storage Blob
Data RBAC). `base/<os>-base-install.wim` holds BYO base WIMs; `captured/<image>/<image>-<buildid>.wim`
holds golden output. See `STORAGE-DESIGN.md`; provisioned by Terraform (PR #313).

## Azure build host (one-time)

The build runs on an Azure VM with **nested virtualization** (for Hyper-V). Stand it
up from any machine with `az`:

```powershell
./New-NucWimBuildVm.ps1 -AllowRdpFrom <your-egress-cidr>
```

That creates `nuc-wim-builder` (Standard_D8s_v5) in `rg-central-us-nuc-wim` on the
existing `sn-central-us-nuc-wim-packer` subnet, attaches a Premium data disk, gives it
a **system-assigned managed identity** granted *Storage Blob Data Contributor* on
`nucwimfxci` (no secrets on the box), and bootstraps Hyper-V + Packer + ADK + azcopy +
git (`scripts/bootstrap-build-host.ps1`, 2-phase around the Hyper-V reboot). SKU must
support nested virt (Dv3/Dv4/Dv5, Ev3+, Fsv2, …).

## Build (on the Azure build host)

RDP in (or `az vm run-command`), clone worker-images, then one command per WIM. The VM
uses its managed identity, so just:

```powershell
az login --identity                 # storage is Entra-only
.\bin\NucWim\New-NucWim.ps1 -Image win11-24h2-hw
```

That runs, per `config/win11-24h2-hw.yaml`:
`prep` (download base WIM → `prepare-base-vhdx` → `register-base-vm`) →
`build` (`packer build`: WU → bake role → sysprep → capture) →
`publish` (upload golden WIM to `captured/<image>/`). Run a subset with `-Stages`, keep
the VM/VHDX with `-KeepArtifacts`, or re-publish a prior build with `-Stages publish -BuildId <id>`.

Publishing to the MDT share for a canary deploy is still a deliberate step:

```powershell
.\scripts\publish-wim.ps1 -Wim .\work\win11-24h2-hw\win11-24h2-hw-<id>.wim -MediaTemplate <share media folder> -ImageName <name>
# On-site MDC1 pulls privately (Entra SP): .\scripts\download-wim.ps1 -Blob captured/win11-24h2-hw/<file> -Dest \\mdt2022...\staging\install.wim
```

## Adding another WIM (scalable — OS version *or* specialized pool)

1. Upload a base WIM to `base/` (convention: `<os>-base-install.wim`), if it's a new OS.
2. Add `config/<image>.yaml` (copy `win11-24h2-hw.yaml`). The image id is the filename.
   - **New OS version:** point `base.wim` at the new base, e.g. `win11-25h2-hw.yaml`.
   - **Specialized pool:** reuse the same `base.wim`, change `bake_role` / `worker_pool_id`,
     e.g. `win11-24h2-perf.yaml`.
3. `.\bin\NucWim\New-NucWim.ps1 -Image <image>`. Names (VHDX, VM, output, blob) are
   namespaced by image id, so builds never collide.

Everything is parameterized; nothing is hardcoded to a machine. Review each script
before running — these touch disks and Sysprep.

## Follow-ups (deferred until the current pipeline is working)

- **Deploy via `DISM /Apply-Image` (Option B in `DEPLOY-INTEGRATION.md`).** Replace
  `setup.exe /unattend` with a direct WIM apply + `bcdboot` + offline
  Panther unattend + offline driver injection. Deferred 2026-07-21: get Option A
  (drop baked WIM into the media folder, keep `setup.exe`) working first; the DISM
  path is a determinism/IO improvement, not the main time win.
- Fast-path the ronin AppX removal script itself (`Remove-AppxProvisionedPackage`
  only, drop the `Wait-AppxIdle`/`Invoke-WithTimeout` loop) — also speeds the
  deploy-time reconciliation run.
- Optionally bake Puppet/Git into the *base* WIM to shave the ~12-min early bootstrap.
