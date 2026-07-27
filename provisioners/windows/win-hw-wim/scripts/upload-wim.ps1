<#
.SYNOPSIS
  Upload a WIM (+ its .sha256) to the private Windows HW WIM storage account.

.DESCRIPTION
  Uses azcopy with Entra auth (--auth-mode login). Storage is Entra-only (no IP
  firewall, no keys): the caller needs an Entra identity with a Storage Blob Data
  Contributor role — the build VM's managed identity, the uploader SP, or a Relops
  member (az login / az login --identity first).

.PARAMETER Wim
  Local WIM path (e.g. .\output\install.wim).

.PARAMETER Container
  Target container: 'captured' (default) or 'base'.

.PARAMETER Account
  Storage account name (default nucwimfxci — the Terraform output).

.EXAMPLE
  az login --service-principal -u $env:AZ_CLIENT_ID -p $env:AZ_CLIENT_SECRET --tenant $env:AZ_TENANT
  .\upload-wim.ps1 -Wim .\output\install.wim -Container captured
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Wim,
    [ValidateSet('captured','base')] [string] $Container = 'captured',
    [string] $Account = 'nucwimfxci',
    # Blob name within the container. Default = the file's leaf name. Set this to
    # namespace the output, e.g. 'win11-24h2-hw/win11-24h2-hw-20260723.wim'.
    [string] $BlobName
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Wim)) { throw "WIM not found: $Wim" }
if (-not (Get-Command azcopy -ErrorAction SilentlyContinue)) { throw 'azcopy not on PATH.' }

if (-not $BlobName) { $BlobName = Split-Path -Leaf $Wim }
# azcopy has its own credential store — it does NOT inherit `az login`. Tell it to
# reuse the az CLI identity (the build VM's managed identity, an SP, or a user).
if (-not $env:AZCOPY_AUTO_LOGIN_TYPE) { $env:AZCOPY_AUTO_LOGIN_TYPE = 'AZCLI' }
$base = "https://$Account.blob.core.windows.net/$Container"
# Upload the WIM and its .sha256 sidecar under the same blob name.
foreach ($pair in @(@{ Src = $Wim; Dest = $BlobName }, @{ Src = "$Wim.sha256"; Dest = "$BlobName.sha256" })) {
    if (Test-Path -LiteralPath $pair.Src) {
        Write-Host "== Uploading $($pair.Src) -> $base/$($pair.Dest) =="
        & azcopy copy "$($pair.Src)" "$base/$($pair.Dest)" --overwrite=ifSourceNewer
        if ($LASTEXITCODE -ne 0) { throw "azcopy upload failed rc=$LASTEXITCODE ($($pair.Dest))" }
    }
}
Write-Host "== Done. =="
