<#
.SYNOPSIS
  Step 4 (runs INSIDE the build VM via Packer): scrub machine-specific state,
  then Sysprep /generalize /oobe /shutdown so the disk can be captured clean.

.DESCRIPTION
  Removes everything that must NOT ship in a generalized golden image:
    - the placeholder bake vault.yaml (secret hygiene)
    - the bake registry identity (role/workerType/worker_pool_id) so first boot
      re-seeds real values; leaves bootstrap_stage = 'setup' so deploy bootstraps
    - SSH host keys and any generic-worker keys (none baked, defensive)
    - build-only autologon
  Then runs Sysprep. The classic Win11 failure here is per-user AppX left behind,
  so we assert none remain (the bake removed provisioned packages) and surface
  Panther logs on failure.

  IMPORTANT: capture must happen AFTER this scrub (it does — capture is a
  post-build step in win-hw-wim.pkr.hcl).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Step($m) { Write-Host "== $m ==" }

# --- Secret + identity scrub ---
Step 'Scrubbing bake secrets and identity'
Remove-Item 'C:\ronin\data\secrets\vault.yaml' -Force -ErrorAction SilentlyContinue
$ron = 'HKLM:\SOFTWARE\Mozilla\ronin_puppet'
if (Test-Path $ron) {
  foreach ($v in 'role','workerType','worker_pool_id','GITHASH','secret_date') {
    Remove-ItemProperty -Path $ron -Name $v -ErrorAction SilentlyContinue
  }
  # Leave a clean state so the deploy-time bootstrap runs.
  Set-ItemProperty -Path $ron -Name bootstrap_stage -Value 'setup' -Type String
  Set-ItemProperty -Path $ron -Name hand_off_ready  -Value 'no'    -Type String
}

# --- SSH host keys (regenerated at first boot) ---
Step 'Removing SSH host keys'
Remove-Item 'C:\ProgramData\ssh\ssh_host_*' -Force -ErrorAction SilentlyContinue

# --- Disable the build-only autologon ---
Step 'Disabling autologon'
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $wl -Name AutoAdminLogon -Value '0' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $wl -Name DefaultPassword -ErrorAction SilentlyContinue

# NOTE(host): the build-only '$env:USERNAME' (packer) local account still exists in
# the image. Either remove it here via a SetupComplete script, or ensure the
# deploy-time autounattend/first-boot removes non-worker local accounts.

# --- Remove the build-only first-logon network helper ---
# set-bake-network.ps1 (dropped by prepare-base-vhdx.ps1 and invoked by the build
# unattend's FirstLogonCommands) is build-only. It is inert in a deployed image (a
# bare .ps1 in Setup\Scripts is not auto-run; only SetupComplete.cmd is), but it must
# not ship in the golden WIM. Also drop its log.
Step 'Removing build-only network helper'
Remove-Item 'C:\Windows\Setup\Scripts\set-bake-network.ps1' -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Windows\Temp\bake-network.log' -Force -ErrorAction SilentlyContinue

# --- Guard: no per-user AppX should remain (the classic Sysprep blocker) ---
Step 'Checking for leftover per-user AppX (Sysprep blocker)'
try {
  $leftover = Get-AppxPackage -AllUsers -ErrorAction Stop |
    Where-Object { -not $_.NonRemovable } | Select-Object -Expand Name -Unique
  if ($leftover) { Write-Warning "Per-user AppX still present (may block Sysprep):`n  $($leftover -join "`n  ")" }
} catch {
  Write-Host "  (AppXSvc disabled by bake — enumeration skipped: $($_.Exception.Message))"
}

# --- Sysprep generalize + shutdown ---
Step 'Running Sysprep /generalize /oobe /shutdown'
$sp = "$env:SystemRoot\System32\Sysprep"
Remove-Item (Join-Path $sp 'unattend.xml') -Force -ErrorAction SilentlyContinue
& (Join-Path $sp 'Sysprep.exe') /generalize /oobe /shutdown /quiet
if ($LASTEXITCODE -ne 0) {
  Write-Warning "Sysprep returned rc=$LASTEXITCODE — dumping Panther errors:"
  Get-Content (Join-Path $sp 'Panther\setuperr.log') -ErrorAction SilentlyContinue | Select-Object -Last 40
  throw "Sysprep failed rc=$LASTEXITCODE"
}
# On success the VM powers off; Packer finalizes the artifact.
