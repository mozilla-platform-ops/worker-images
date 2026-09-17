<#
.SYNOPSIS
  Download a WIM from the private Windows HW WIM storage account (base or captured).
  Used on the Packer host (fetch base) and on the on-site MDC1 server (fetch
  captured -> MDT share).

.DESCRIPTION
  Two auth modes:
    -AuthMode login : Entra SP/managed identity (run `az login --service-principal`
                      first). Preferred.
    -AuthMode sas   : append a read-only SAS token (from Key Vault) via -Sas.
  Storage is Entra-only (no IP firewall, no keys): the caller needs an Entra
  identity with a Storage Blob Data role (managed identity, SP, or a Relops member).

.EXAMPLE
  # Packer host, Entra:
  .\download-wim.ps1 -Blob resources/WIMs/win11-24h2-base-install.wim -Dest D:\images\install.wim

  # MDC1 server, SAS:
  .\download-wim.ps1 -Blob captured/WIMs/win11-24h2-hw/win11-24h2-hw.wim -Dest \\mdt2022\deployments\staging\install.wim -AuthMode sas -Sas $sas
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Blob,     # e.g. captured/WIMs/<image>/<wim>
    [Parameter(Mandatory)] [string] $Dest,
    [string] $Account = 'hardwareimaging',
    [ValidateSet('login','sas')] [string] $AuthMode = 'login',
    [string] $Sas
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command azcopy -ErrorAction SilentlyContinue)) { throw 'azcopy not on PATH.' }

$url = "https://$Account.blob.core.windows.net/$Blob"
$destDir = Split-Path -Parent $Dest
if ($destDir -and -not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

if ($AuthMode -eq 'sas') {
    if (-not $Sas) { throw '-Sas required when -AuthMode sas' }
    $sep = if ($Sas.StartsWith('?')) { '' } else { '?' }
    & azcopy copy "$url$sep$Sas" "$Dest" --overwrite=ifSourceNewer
} else {
    # azcopy has its own credential store — it does NOT inherit `az login`. Tell it
    # to reuse the az CLI identity (the VM's managed identity, an SP, or a user).
    # (azcopy 10.32 dropped --auth-mode on copy; AZCOPY_AUTO_LOGIN_TYPE drives OAuth.)
    if (-not $env:AZCOPY_AUTO_LOGIN_TYPE) { $env:AZCOPY_AUTO_LOGIN_TYPE = 'AZCLI' }
    & azcopy copy "$url" "$Dest" --overwrite=ifSourceNewer
}
if ($LASTEXITCODE -ne 0) { throw "azcopy download failed rc=$LASTEXITCODE" }

# Verify SHA-256 if a sidecar is present next to the source.
Write-Host "== Downloaded $Blob -> $Dest =="
Write-Host "   (verify against captured/<wim>.sha256 if present)"
