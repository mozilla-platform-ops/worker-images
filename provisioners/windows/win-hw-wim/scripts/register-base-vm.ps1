<#
.SYNOPSIS
  Wrap the prepared base VHDX in a pristine Gen2 Hyper-V VM that Packer clones
  from (source.hyperv-vmcx.clone_from_vm_name). Cloning leaves this VM untouched,
  so you can rebuild repeatedly from a clean base.

.DESCRIPTION
  Run on the Windows host, elevated, after prepare-base-vhdx.ps1. Creates a
  Generation 2 VM pointing at the VHDX, sets firmware to boot from the disk, and
  configures Secure Boot to match win-hw-wim.pkr.hcl (MicrosoftWindows template).
  The VM is left OFF; Packer clones and boots a copy.

.EXAMPLE
  .\register-base-vm.ps1 -VmName win-hw-wim-base -Vhdx .\output\base.vhdx -SwitchName "Default Switch"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $VmName,
    [Parameter(Mandatory)] [string] $Vhdx,
    [Parameter(Mandatory)] [string] $SwitchName,
    [int] $MemoryStartupMB = 8192,
    [int] $Cpus = 4
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $Vhdx)) { throw "VHDX not found: $Vhdx" }
$Vhdx = (Resolve-Path -LiteralPath $Vhdx).Path

if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {
    throw "VM '$VmName' already exists. Remove it first (Remove-VM) or choose another name."
}

Write-Host "== Creating Gen2 VM '$VmName' from $Vhdx =="
$vm = New-VM -Name $VmName -Generation 2 -MemoryStartupBytes ($MemoryStartupMB * 1MB) `
             -VHDPath $Vhdx -SwitchName $SwitchName
Set-VM -Name $VmName -ProcessorCount $Cpus -AutomaticCheckpointsEnabled $false

# Boot from the OS disk; Secure Boot template must match the Packer source.
$drive = Get-VMHardDiskDrive -VMName $VmName
Set-VMFirmware -VMName $VmName -FirstBootDevice $drive `
               -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows

Write-Host "== Done. Set source_vm_name = '$VmName' in your *.auto.pkrvars.hcl =="
Write-Host "   Packer will clone this VM; leave it powered off."
