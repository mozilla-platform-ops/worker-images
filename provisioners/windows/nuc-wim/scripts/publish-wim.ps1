<#
.SYNOPSIS
  Step 6 (Windows host): publish the baked install.wim into the MDT/WDS deployment
  share so the existing OS-deploy.ps1 + PXE dance applies it.

.DESCRIPTION
  Copies the baked install.wim into an image media folder on the share, replacing
  sources\install.wim inside a copy of the standard Win11 media. OS-deploy.ps1
  copies "Images\<ImageName>" to the node and runs setup.exe /unattend, so the
  baked WIM must live at Images\<ImageName>\sources\install.wim.

  Verifies the SHA-256 before copying. Does NOT edit pools.yml (that is a commit
  to worker-images main; see DEPLOY-INTEGRATION.md — do it via PR, not here).

.EXAMPLE
  .\publish-wim.ps1 -Wim .\output\install.wim `
     -MediaTemplate "\\mdt2022.ad.mozilla.com\deployments\Images\win11-24H2-NUC-01-16-2025" `
     -ImageName "win11-24H2-NUC-baked-2026-07-17"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Wim,
    [Parameter(Mandatory)] [string] $MediaTemplate,   # existing extracted-ISO media folder to clone
    [Parameter(Mandatory)] [string] $ImageName,       # new folder name under Images\
    [switch] $WhatIf
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $Wim)) { throw "WIM not found: $Wim" }
if (Test-Path "$Wim.sha256") {
    $expected = (Get-Content "$Wim.sha256").Split(' ')[0]
    $actual   = (Get-FileHash -Algorithm SHA256 -Path $Wim).Hash
    if ($expected -ne $actual) { throw "SHA-256 mismatch for $Wim (expected $expected, got $actual)" }
    Write-Host "SHA-256 verified: $actual"
}

$dest = Join-Path (Split-Path -Parent $MediaTemplate) $ImageName
Write-Host "== Will clone media template -> $dest and swap in baked install.wim =="
if ($WhatIf) { Write-Host '(WhatIf) no changes made'; return }

if (Test-Path -LiteralPath $dest) { throw "Destination already exists: $dest" }
Copy-Item -LiteralPath $MediaTemplate -Destination $dest -Recurse -Force

$target = Join-Path $dest 'sources\install.wim'
$esd    = Join-Path $dest 'sources\install.esd'
if (Test-Path $esd) { Remove-Item $esd -Force }   # setup prefers install.wim if present
Copy-Item -LiteralPath $Wim -Destination $target -Force

Write-Host "== Published. Point pools.yml image: -> $ImageName (via worker-images PR) =="
Write-Host "   Then update base-autounattend.xml image index to the captured index (see DEPLOY-INTEGRATION.md)."
