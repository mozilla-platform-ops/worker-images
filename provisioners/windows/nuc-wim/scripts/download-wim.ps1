<#
.SYNOPSIS
  Download a WIM from the private NUC WIM storage account (base or captured).
  Used on the Packer host (fetch base) and on the on-site MDC1 server (fetch
  captured -> MDT share).

.DESCRIPTION
  Two auth modes:
    -AuthMode login : Entra SP/managed identity (run `az login --service-principal`
                      first). Preferred.
    -AuthMode sas   : append a read-only SAS token (from Key Vault) via -Sas.
  The account firewall must allow the caller's network / egress IP.

.EXAMPLE
  # Packer host, Entra:
  .\download-wim.ps1 -Blob base/install.wim -Dest D:\images\install.wim

  # MDC1 server, SAS:
  .\download-wim.ps1 -Blob captured/install.wim -Dest \\mdt2022\deployments\staging\install.wim -AuthMode sas -Sas $sas
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Blob,     # e.g. captured/install.wim
    [Parameter(Mandatory)] [string] $Dest,
    [string] $Account = 'nucwimfxci',
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
    $sep = ($Sas.StartsWith('?')) ? '' : '?'
    & azcopy copy "$url$sep$Sas" "$Dest" --overwrite=ifSourceNewer
} else {
    & azcopy copy "$url" "$Dest" --auth-mode login --overwrite=ifSourceNewer
}
if ($LASTEXITCODE -ne 0) { throw "azcopy download failed rc=$LASTEXITCODE" }

# Verify SHA-256 if a sidecar is present next to the source.
Write-Host "== Downloaded $Blob -> $Dest =="
Write-Host "   (verify against captured/<wim>.sha256 if present)"
