<#
.SYNOPSIS
  Inject-library script 'nocheck': make Windows 11 install media bypass the hardware requirement
  checks (TPM 2.0 / Secure Boot / RAM / CPU / storage) so it clean-installs on unsupported hardware.

.DESCRIPTION
  One of the reusable scripts under scripts/inject/, referenced by name from a config's `scripts:`
  list and run by create-iso.ps1 against the extracted install media before repackaging. Writes an
  autounattend.xml at the media root whose windowsPE pass sets HKLM\SYSTEM\Setup\LabConfig bypass
  keys + MoSetup AllowUpgradesWithUnsupportedTPMOrCPU BEFORE Setup's compat check; Setup then
  continues normally. Ref: https://woshub.com/upgrade-to-windows-11-unsupported-pc/

  Inject-script contract: takes -MediaDir (the extracted media root) and modifies it in place.

.PARAMETER MediaDir
  Path to the extracted install media (ISO contents) to modify.
#>
[CmdletBinding()]
param([Parameter(Mandatory)] [string] $MediaDir)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $MediaDir)) { throw "nocheck: MediaDir not found: $MediaDir" }

$autounattend = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add HKLM\System\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>reg add HKLM\System\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>3</Order><Path>reg add HKLM\System\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>4</Order><Path>reg add HKLM\System\Setup\LabConfig /v BypassCPUCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>5</Order><Path>reg add HKLM\System\Setup\LabConfig /v BypassStorageCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add"><Order>6</Order><Path>reg add HKLM\System\Setup\MoSetup /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
</unattend>
'@
[System.IO.File]::WriteAllText((Join-Path $MediaDir 'autounattend.xml'), $autounattend, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "  nocheck: wrote requirement-bypass autounattend.xml (LabConfig + MoSetup) to $MediaDir"
