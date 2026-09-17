<#
.SYNOPSIS
  Extract the base install.wim from a Windows install ISO (the media's
  sources\install.wim), so a WIM bake can start from just an uploaded ISO when no
  base WIM exists yet.

.DESCRIPTION
  Mounts the ISO, copies out sources\install.wim (the full multi-edition OS image, so
  edition-name resolution in prepare-base-vhdx still works). If the media ships a
  compressed sources\install.esd instead (consumer media), every edition is exported
  into a WIM with Export-WindowsImage so the result is edition-equivalent. Writes an
  <OutWim>.sha256 sidecar (so upload-wim.ps1 can publish both).

  Runs on the Windows build host: needs Mount-DiskImage (elevation) and DISM
  (Get-WindowsImage / Export-WindowsImage) for the .esd path. NOT a ronin operation —
  this only lifts the OS image out of the media; no worker content is baked here.

.PARAMETER SourceIso
  Path to the Windows install ISO to extract from.

.PARAMETER OutWim
  Path to write the extracted base WIM (convention: <os>-base-install.wim).

.EXAMPLE
  .\extract-wim-from-iso.ps1 -SourceIso F:\wim-work\Win11_25H2_English_x64_v2.iso `
                             -OutWim   F:\wim-work\win11-25h2-hw\win11-25h2-base-install.wim
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SourceIso,
    [Parameter(Mandatory)] [string] $OutWim
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $SourceIso)) { throw "SourceIso not found: $SourceIso" }

$outDir = Split-Path -Parent $OutWim
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
if (Test-Path -LiteralPath $OutWim) { Remove-Item -LiteralPath $OutWim -Force }

Write-Host "== Mounting $SourceIso =="
$mount = Mount-DiskImage -ImagePath $SourceIso -PassThru
try {
    $vol = ($mount | Get-Volume).DriveLetter
    if (-not $vol) { Start-Sleep -Seconds 2; $vol = ($mount | Get-Volume).DriveLetter }
    if (-not $vol) { throw 'Could not determine the mounted ISO drive letter.' }
    $srcWim = "${vol}:\sources\install.wim"
    $srcEsd = "${vol}:\sources\install.esd"
    if (Test-Path -LiteralPath $srcWim) {
        Write-Host "== Copying $srcWim -> $OutWim =="
        Copy-Item -LiteralPath $srcWim -Destination $OutWim -Force
    }
    elseif (Test-Path -LiteralPath $srcEsd) {
        # Consumer media ships a compressed install.esd; export every edition into a WIM
        # so edition-name resolution (prepare-base-vhdx) still works.
        Write-Host "== No install.wim; exporting editions from $srcEsd -> $OutWim =="
        foreach ($img in (Get-WindowsImage -ImagePath $srcEsd)) {
            Write-Host "   export index $($img.ImageIndex): $($img.ImageName)"
            Export-WindowsImage -SourceImagePath $srcEsd -SourceIndex $img.ImageIndex `
                -DestinationImagePath $OutWim -CompressionType Max | Out-Null
        }
    }
    else {
        throw "Neither sources\install.wim nor sources\install.esd found on $SourceIso - not a Windows install ISO?"
    }
}
finally {
    Dismount-DiskImage -ImagePath $SourceIso | Out-Null
}

# sha256 sidecar (upload-wim.ps1 publishes <wim>.sha256 alongside).
$hash = (Get-FileHash -LiteralPath $OutWim -Algorithm SHA256).Hash.ToLower()
[System.IO.File]::WriteAllText("$OutWim.sha256", "$hash  $(Split-Path -Leaf $OutWim)", [System.Text.ASCIIEncoding]::new())
$sizeGb = [math]::Round((Get-Item -LiteralPath $OutWim).Length / 1GB, 2)
Write-Host "== Extracted base WIM: $OutWim ($sizeGb GB)  sha256=$hash =="
