# Runs on the Hyper-V host after the last WinRM provisioner has finished.
[CmdletBinding()]
param([string] $VMName = 'packer-nuc')

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrEmpty($env:WIM_BUILD_PASSWORD)) {
    throw 'WIM_BUILD_PASSWORD must contain the build-scoped packer password.'
}
$credential = New-Object System.Management.Automation.PSCredential(
    'packer', (ConvertTo-SecureString $env:WIM_BUILD_PASSWORD -AsPlainText -Force))

# VMBus remoting survives removal of the guest's WinRM listener and firewall rule.
# Do not swallow errors: cleanup or Sysprep failure must prevent shutdown/capture.
Invoke-Command -VMName $VMName -Credential $credential `
    -FilePath (Join-Path $PSScriptRoot 'sysprep-generalize.ps1') -ErrorAction Stop
Stop-VM -Name $VMName -ErrorAction Stop
