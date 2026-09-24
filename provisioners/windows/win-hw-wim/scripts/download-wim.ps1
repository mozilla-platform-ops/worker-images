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
    [string] $Sas,
    [switch] $SkipSidecar
)
$ErrorActionPreference = 'Stop'
if (-not (Get-Command azcopy -ErrorAction SilentlyContinue)) { throw 'azcopy not on PATH.' }

$destDir = Split-Path -Parent $Dest
if ($destDir -and -not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }

if ($AuthMode -eq 'sas' -and -not $Sas) { throw '-Sas required when -AuthMode sas' }
if ($AuthMode -eq 'login' -and -not $env:AZCOPY_AUTO_LOGIN_TYPE) {
    # azcopy does not inherit `az login`; reuse the az CLI identity.
    $env:AZCOPY_AUTO_LOGIN_TYPE = 'AZCLI'
}

$downloads = @(@{ Blob = $Blob; Dest = $Dest })
if (-not $SkipSidecar) { $downloads += @{ Blob = "$Blob.sha256"; Dest = "$Dest.sha256" } }
foreach ($pair in $downloads) {
    $url = "https://$Account.blob.core.windows.net/$($pair.Blob)"
    if ($AuthMode -eq 'sas') {
        $sep = if ($Sas.StartsWith('?')) { '' } else { '?' }
        $url = "$url$sep$Sas"
    }
    & azcopy copy $url $pair.Dest --overwrite=true
    if ($LASTEXITCODE -ne 0) { throw "azcopy download failed rc=$LASTEXITCODE ($($pair.Blob))" }
}

if ($SkipSidecar) {
    Write-Host "== Downloaded $Blob -> $Dest =="
}
else {
    $sidecar = Get-Content -LiteralPath "$Dest.sha256" -Raw
    if ($sidecar -notmatch '^\s*([0-9a-fA-F]{64})(?:\s|$)') {
        throw "Invalid SHA-256 sidecar: $Dest.sha256"
    }
    $expected = $Matches[1]
    $actual = (Get-FileHash -LiteralPath $Dest -Algorithm SHA256).Hash
    if ($actual -ne $expected) {
        throw "SHA-256 mismatch for $Dest (expected $expected, got $actual)"
    }
    Write-Host "== Downloaded and SHA-256 verified $Blob -> $Dest ($actual) =="
}
