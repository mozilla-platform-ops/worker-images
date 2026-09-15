# Deploy integration + first-boot personalization

How the baked `install.wim` plugs into the existing NUC deploy flow, and what
still happens at first boot. All `worker-images` / `ronin_puppet` edits below go
via **feature branch + PR — never a push to main**.

## Where it slots in (existing MDC1Windows flow)

Today `provisioners/windows/MDC1Windows/OS-deploy.ps1` (in WinPE):
1. partitions the disk, mounts the MDT share as `Z:`,
2. copies `Z:\Images\<pool.image>` → `D:\<image>` (extracted Win11 media),
3. templates `autounattend.xml` (disk/partition, hostname, admin pw),
4. runs `setup.exe /unattend:autounattend.xml`. Setup applies
   `sources\install.wim` **index 3**.

`<pool.image>` comes from `pools.yml` (`image:` field).

### Option A — drop-in (recommended, least change)
1. `publish-wim.ps1` clones the media folder and swaps in the baked WIM at
   `Images\<ImageName>\sources\install.wim`.
2. In `worker-images` (PR): set the hw pool's `image:` in
   `provisioners/windows/MDC1Windows/pools.yml` to `<ImageName>`.
3. In `worker-images` (PR): set the install image index/name in
   `base-autounattend.xml` to match the captured image. A custom captured WIM is
   index **1** (not 3):
   ```xml
   <InstallFrom><MetaData wcm:action="add">
     <Key>/IMAGE/INDEX</Key><Value>1</Value>
   </MetaData></InstallFrom>
   ```
   (or switch to an `/IMAGE/NAME` key = `win11-24h2-ci-baked`).
   Everything else in the autounattend (hostname/disk/password templating,
   FirstLogonCommands → `Get-Bootstrap.ps1`) stays as-is.

### Option B — full DISM apply (DEFERRED follow-up)

> **Status: deferred.** Decision (2026-07-21): ship Option A first and get the
> current bake→publish→deploy pipeline working end-to-end; take on the DISM
> `/Apply-Image` conversion afterward. Rationale: the imaging phase is only ~13 of
> the ~63 min, so the DISM win is modest vs. the ~30-min AppX bake — its value is
> determinism + dropping the ~5 GB media copy and the `setup.exe` variable, not
> raw minutes. When we do it, fold in offline driver injection at the same time.

Replace `OS-deploy.ps1:750-754` (`Start-Process setup.exe /unattend`) with:
```powershell
dism /Apply-Image /ImageFile:D:\<image>\sources\install.wim /Index:1 /ApplyDir:W:\ /CheckIntegrity /Verify
W:\Windows\System32\bcdboot W:\Windows /s S: /f UEFI
```
Keep the partition/format block (`:151-261`) and the secret copy (`:681-684`).
Drive specialize/OOBE from an offline-injected unattend instead of the windowsPE
pass. More work; only pursue if you want to drop `setup.exe` entirely.

### Driver injection (both options)
The bake VM lacks NUC hardware, so inject NUC drivers into the applied offline
image at deploy:
```powershell
dism /Image:W:\ /Add-Driver /Driver:Z:\Drivers\NUC13 /Recurse
```

## First-boot personalization (unchanged, but one guard)

First boot still runs the existing chain: `autounattend` FirstLogonCommands →
`Get-Bootstrap.ps1` → `bootstrap.ps1`. Because the stable catalog is already
baked, this run is short and does only the machine-specific work:

- **Seed identity** into `HKLM:\SOFTWARE\Mozilla\ronin_puppet`
  (`role`, `workerType`, `worker_pool_id`, `GITHASH`, `secret_date`) — from the
  pool, via `Set-Ronin-Registry`.
- **Copy the dated secret** `D:\secrets\<pool>-<date>.yaml` → ronin
  `data\secrets\vault.yaml` (`Get-Ronin`).
- **Run the FULL `win116424h2hw` role** `puppet apply` — now fast/idempotent
  because AppX/updates/packages are baked; it applies the four deploy-time
  profiles (`windows_worker_runner`, `microsoft_kms`, `nuc_bios`,
  `nuc_management`) and registers worker-runner.

### Required guard (ronin PR, feature branch)
`bootstrap.ps1`'s `Get-Ronin` currently **deletes and re-clones** `C:\ronin`
every run (`~:645-647`). To reuse the baked checkout (and keep first boot fast),
guard that so a deploy-time run reuses the pre-baked repo when the pinned hash
already matches:
```powershell
if ((Test-Path $ronin_repo) -and ((git -C $ronin_repo rev-parse HEAD) -like "$hash*")) {
    # reuse baked checkout
} else {
    Remove-Item $ronin_repo -Recurse -Force; git clone ...
}
```
(If you prefer zero bootstrap changes, leave it — the re-clone costs ~1 min; the
big win is AppX, not the clone.)

## Verify on a canary NUC

1. `publish-wim.ps1` → baked WIM on the share; pools.yml/autounattend pointed at it.
2. PXE-dance `nuc13-004` (see `PXE_DANCE_RUNBOOK.md` / `AuditAndPXE.ps1`).
3. Re-run the SolarWinds timing analysis (filter `nuc13-004`) and compare to the
   ~63 min / ~30-min-AppX baseline. Target ≈ 20–25 min, worker-runner healthy.
4. SSH-check: `bootstrap_stage=complete`, `last_run_exit` ∈ {0,2}, AppX already
   absent (bake worked), worker claims a task.
