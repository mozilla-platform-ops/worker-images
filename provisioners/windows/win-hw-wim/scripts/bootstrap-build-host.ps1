<#
.SYNOPSIS
  Prepare an Azure VM to be a win-hw-wim build host: nested Hyper-V + the tooling the
  Packer WIM pipeline needs. Runs ON the VM (via az vm run-command from
  New-WinHwWimBuildVm.ps1, or manually).

.DESCRIPTION
  Two phases because enabling Hyper-V needs a reboot:
    -Phase Hyperv   : enable the Hyper-V role (no auto-reboot; caller restarts).
    -Phase Tooling  : install Packer, Windows ADK (DISM), azcopy, git, az CLI,
                      and the powershell-yaml module. Safe to re-run.

  Requires a nested-virtualization-capable VM SKU (Dv3/Dv4/Dv5, Ev3+, Fsv2, ...).

.EXAMPLE
  .\bootstrap-build-host.ps1 -Phase Hyperv   ; Restart-Computer
  .\bootstrap-build-host.ps1 -Phase Tooling
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Hyperv', 'Tooling')] [string] $Phase,
    [string] $DataDriveLetter = 'F'   # large disk for build artifacts (work/)
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Phase -eq 'Hyperv') {
    Write-Host '== Enabling Hyper-V role (reboot required afterwards) =='
    $r = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools
    Write-Host "  Success=$($r.Success) RestartNeeded=$($r.RestartNeeded)"
    Write-Host '== Done. Caller must reboot before -Phase Tooling. =='
    return
}

# ---- Phase: Tooling ----------------------------------------------------------
if (-not (Get-WindowsFeature -Name Hyper-V).Installed) {
    throw 'Hyper-V not installed yet. Run -Phase Hyperv and reboot first.'
}

# Initialize + mount the data disk (if a raw disk is attached) for build artifacts.
$raw = Get-Disk | Where-Object PartitionStyle -eq 'RAW' | Select-Object -First 1
if ($raw) {
    Write-Host "== Initializing data disk #$($raw.Number) as $DataDriveLetter: =="
    $raw | Initialize-Disk -PartitionStyle GPT -PassThru |
        New-Partition -DriveLetter $DataDriveLetter -UseMaximumSize |
        Format-Volume -FileSystem NTFS -NewFileSystemLabel 'build' -Confirm:$false | Out-Null
}

# Chocolatey (simplest reliable installer source for packer/azcopy/git/az on Windows).
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Host '== Installing Chocolatey =='
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:Path += ";$env:ProgramData\chocolatey\bin"
}

foreach ($pkg in 'packer', 'azcopy10', 'git', 'azure-cli', 'windows-adk-deploymenttools') {
    Write-Host "== choco install $pkg =="
    & choco install $pkg -y --no-progress --limit-output
    if ($LASTEXITCODE -notin 0, 3010) { Write-Warning "choco $pkg rc=$LASTEXITCODE" }
}

Write-Host '== Installing powershell-yaml module =='
if (-not (Get-Module -ListAvailable powershell-yaml)) {
    Install-Module powershell-yaml -Scope AllUsers -Force -Confirm:$false
}

Write-Host '== Build host ready. Verify: packer version; azcopy --version; dism /? ; az version =='
