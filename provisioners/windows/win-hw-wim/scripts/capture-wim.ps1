<#
.SYNOPSIS
  Step 5 (runs on the Windows HOST, elevated, after the Packer build): capture the
  generalized VHDX into a golden install.wim.

.DESCRIPTION
  Finds the generalized VHDX in the Packer output directory, mounts it, locates
  the Windows volume, and runs DISM /Capture-Image. Records a SHA-256. Always
  dismounts the VHDX.

.PARAMETER BuildDir
  Packer output_directory (contains the cloned VM + its Virtual Hard Disks).

.PARAMETER OutWim
  Destination install.wim path.

.PARAMETER Name
  Image /Name metadata.

.EXAMPLE
  .\capture-wim.ps1 -BuildDir .\output\build -OutWim .\output\install.wim
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $BuildDir,
    [Parameter(Mandatory)] [string] $OutWim,
    [string] $Name = 'win11-24h2-ci-baked'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Must run elevated (Administrator).'
}

$vhdx = Get-ChildItem -Path $BuildDir -Recurse -Filter *.vhdx -ErrorAction Stop |
        Sort-Object Length -Descending | Select-Object -First 1
if (-not $vhdx) { throw "No .vhdx found under $BuildDir" }
Write-Host "== Capturing from $($vhdx.FullName) =="

$outDir = Split-Path -Parent $OutWim
if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
if (Test-Path $OutWim) { throw "OutWim already exists (refusing to overwrite): $OutWim" }

$mounted = $null
try {
    $before = (Get-Volume).DriveLetter
    Mount-VHD -Path $vhdx.FullName
    $mounted = $vhdx.FullName
    Start-Sleep -Seconds 2
    # The Windows volume = the new NTFS volume that appeared with a \Windows dir.
    $win = Get-Volume | Where-Object {
        $_.DriveLetter -and ($_.DriveLetter -notin $before) -and
        (Test-Path ("{0}:\Windows\System32\ntoskrnl.exe" -f $_.DriveLetter))
    } | Select-Object -First 1
    if (-not $win) { throw 'Could not locate the Windows volume on the mounted VHDX.' }
    $root = "$($win.DriveLetter):\"
    Write-Host "== Windows volume: $root =="

    Write-Host "== DISM /Capture-Image -> $OutWim =="
    New-WindowsImage -ImagePath $OutWim -CapturePath $root -Name $Name `
        -Description "Baked Windows HW CI image (ronin bake role)" -CompressionType Max -Verify | Out-Null
}
finally {
    if ($mounted) { Dismount-VHD -Path $mounted -ErrorAction SilentlyContinue }
}

$sha = (Get-FileHash -Algorithm SHA256 -Path $OutWim).Hash
$sizeGB = [math]::Round((Get-Item $OutWim).Length / 1GB, 2)
"$sha  $(Split-Path -Leaf $OutWim)" | Set-Content -Path "$OutWim.sha256"
Write-Host "== Captured $OutWim ($sizeGB GB) =="
Write-Host "   SHA256: $sha"
# Best-effort image-info dump. Normalize to backslashes: DISM /Capture-Image tolerates the
# forward-slash path Packer passes, but the Get-WindowsImage cmdlet rejects it with "The
# parameter is incorrect" (0x80070057). Never fail the capture on a verification hiccup -
# the WIM and its .sha256 already exist at this point.
try {
  $wimPath = ([string]$OutWim).Replace('/', '\')
  Get-WindowsImage -ImagePath $wimPath | Format-List ImageName, ImageIndex, ImageSize
}
catch {
  $vmsg = $_.Exception.Message
  Write-Warning ("  (image-info verification skipped: " + $vmsg + ")")
}
