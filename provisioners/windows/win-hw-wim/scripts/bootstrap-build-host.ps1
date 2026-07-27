<#
.SYNOPSIS
  Prepare an Azure VM to be a win-hw-wim build host: nested Hyper-V + tooling.
  Runs ON the VM via `az vm run-command`.

.DESCRIPTION
  Driven by a script-scope $Phase variable (NOT a param) because
  `az vm run-command --parameters` does not reliably map to script parameters —
  the caller prepends `$Phase = 'Hyperv'` (or 'Tooling') as a separate --scripts line.

    Hyperv  : enable the Hyper-V role (caller reboots afterward).
    Tooling : install Packer, azcopy, git, az CLI (DISM is native), powershell-yaml.

  On success each phase prints the sentinel BOOTSTRAP_PHASE_OK — the caller asserts it,
  because `az vm run-command` returns exit 0 even when the inner script throws.
  Needs a nested-virtualization-capable SKU (Dv3/Dv4/Dv5, Ev3+, Fsv2, ...).
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $Phase) { throw "Set `$Phase to 'Hyperv' or 'Tooling' before running this script." }
if ($Phase -notin @('Hyperv', 'Tooling')) { throw "Invalid `$Phase '$Phase' (expected Hyperv or Tooling)." }
$DataDriveLetter = 'F'

if ($Phase -eq 'Hyperv') {
    Write-Host '== Enabling Hyper-V role (reboot required afterwards) =='
    $r = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools
    Write-Host "  Success=$($r.Success) RestartNeeded=$($r.RestartNeeded)"
    if (-not $r.Success) { throw "Install-WindowsFeature Hyper-V failed: $($r | Out-String)" }
    Write-Output 'BOOTSTRAP_PHASE_OK'
    return
}

# ---- Phase: Tooling ----------------------------------------------------------
if (-not (Get-WindowsFeature -Name Hyper-V).Installed) {
    throw 'Hyper-V not installed yet. Run Phase Hyperv and reboot first.'
}

# Initialize + mount the data disk (if a raw disk is attached) for build artifacts.
$raw = Get-Disk | Where-Object PartitionStyle -eq 'RAW' | Select-Object -First 1
if ($raw) {
    Write-Host "== Initializing data disk #$($raw.Number) as ${DataDriveLetter}: =="
    $raw | Initialize-Disk -PartitionStyle GPT -PassThru |
        New-Partition -DriveLetter $DataDriveLetter -UseMaximumSize |
        Format-Volume -FileSystem NTFS -NewFileSystemLabel 'build' -Confirm:$false | Out-Null
}

# Chocolatey.
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Host '== Installing Chocolatey =='
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:Path += ";$env:ProgramData\chocolatey\bin"
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) { throw 'Chocolatey install failed.' }
}

# DISM is built into Windows (System32) — no ADK package needed for the WIM
# apply/capture cmdlets (Expand-WindowsImage / New-WindowsImage) the pipeline uses.
foreach ($pkg in 'packer', 'azcopy10', 'git', 'azure-cli') {
    Write-Host "== choco install $pkg =="
    & choco install $pkg -y --no-progress --limit-output
    if ($LASTEXITCODE -notin 0, 3010) { throw "choco install $pkg failed rc=$LASTEXITCODE" }
}

Write-Host '== Installing powershell-yaml module =='
if (-not (Get-Module -ListAvailable powershell-yaml)) {
    Install-Module powershell-yaml -Scope AllUsers -Force -Confirm:$false
}

# Refresh PATH from the machine env so the just-installed tools resolve now.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

# Verify the toolchain actually installed (fail loudly — run-command hides inner errors).
$missing = @()
foreach ($t in 'packer', 'git', 'azcopy', 'az', 'dism') {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { $missing += $t }
}
if ($missing) { throw "Tooling missing after install: $($missing -join ', ')" }

Write-Host '== Build host ready (packer/git/azcopy/az/dism present). =='
Write-Output 'BOOTSTRAP_PHASE_OK'
