<#
.SYNOPSIS
  Step 1 of the wim-packer pipeline: apply a bring-your-own base install.wim into
  a bootable UEFI/GPT VHDX that Packer's Hyper-V builder can boot.

.DESCRIPTION
  Creates a dynamic VHDX, partitions it GPT (EFI + MSR + Windows), applies the
  chosen image index from the source WIM with DISM, and writes UEFI boot files
  with bcdboot. The result is a generation-2 (UEFI) bootable disk.

  Run on the Windows host in an ELEVATED PowerShell. This touches disks via
  diskpart-equivalent cmdlets scoped to the new VHDX only (never a physical disk).

.PARAMETER SourceWim
  Path to your base install.wim (Win11 24H2).

.PARAMETER OutVhdx
  Path of the VHDX to create.

.PARAMETER Index
  Image index inside the WIM to apply (default 1). Use Get-WindowsImage to list.

.PARAMETER SizeGB
  Maximum (dynamic) size of the VHDX. Default 80.

.EXAMPLE
  .\prepare-base-vhdx.ps1 -SourceWim D:\images\install.wim -OutVhdx .\output\base.vhdx -Index 1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SourceWim,
    [Parameter(Mandatory)] [string] $OutVhdx,
    # Pick the image inside the WIM by edition NAME (resolved to an index via
    # Get-WindowsImage). Falls back to -Index when -Edition is not given.
    [string] $Edition,
    [int] $Index = 0,
    [int] $SizeGB = 80,
    # Optional offline driver injection (DISM /Add-Driver) into the applied image.
    [switch] $InjectDrivers,
    [string] $DriverCabUrl,
    # Build-only WinRM account injected via unattend so Packer can connect.
    # Scrubbed by sysprep-generalize.ps1 before capture — never ships in the WIM.
    [string] $WinRMUser = 'packer',
    [Parameter(Mandatory)] [string] $WinRMPassword,
    [string] $ComputerName = 'nuc-bake'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Must run elevated (Administrator).'
    }
}

Assert-Admin
if (-not (Test-Path -LiteralPath $SourceWim)) { throw "SourceWim not found: $SourceWim" }
$SourceWim = (Resolve-Path -LiteralPath $SourceWim).Path

# Resolve output path (may not exist yet) and ensure parent dir.
$outDir = Split-Path -Parent $OutVhdx
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
# Make relative paths absolute against the CWD, but leave an already-rooted path
# alone — Join-Path'ing a rooted path onto the CWD yields 'C:\cwd\C:\...' which
# GetFullPath rejects ("path's format is not supported").
if (-not [System.IO.Path]::IsPathRooted($OutVhdx)) { $OutVhdx = Join-Path (Get-Location) $OutVhdx }
$OutVhdx = [System.IO.Path]::GetFullPath($OutVhdx)
if (Test-Path -LiteralPath $OutVhdx) { throw "OutVhdx already exists (refusing to overwrite): $OutVhdx" }

# Resolve the image index from the edition name when provided.
if ($Edition) {
    $all = Get-WindowsImage -ImagePath $SourceWim
    $match = $all | Where-Object { $_.ImageName -eq $Edition }
    if (-not $match) {
        $list = ($all | ForEach-Object { '[{0}] {1}' -f $_.ImageIndex, $_.ImageName }) -join '; '
        throw "Edition '$Edition' not found in $SourceWim. Available: $list"
    }
    $Index = [int]($match | Select-Object -First 1).ImageIndex
    Write-Host "== Resolved edition '$Edition' -> index $Index =="
}
elseif ($Index -le 0) {
    $Index = 1
}

Write-Host "== Validating source WIM index $Index =="
$img = Get-WindowsImage -ImagePath $SourceWim -Index $Index
Write-Host ("  {0}  ({1})" -f $img.ImageName, $img.Architecture)

$vhd = $null
try {
    Write-Host "== Creating VHDX ($SizeGB GB dynamic): $OutVhdx =="
    New-VHD -Path $OutVhdx -SizeBytes ($SizeGB * 1GB) -Dynamic | Out-Null

    Write-Host "== Mounting and partitioning (GPT: EFI + MSR + Windows) =="
    $vhd  = Mount-VHD -Path $OutVhdx -Passthru | Get-Disk
    Initialize-Disk -Number $vhd.Number -PartitionStyle GPT -Confirm:$false | Out-Null

    # EFI System Partition (260 MB, FAT32)
    $efi = New-Partition -DiskNumber $vhd.Number -Size 260MB -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    Format-Volume -Partition $efi -FileSystem FAT32 -NewFileSystemLabel 'System' -Confirm:$false | Out-Null
    $efi | Set-Partition -NewDriveLetter 'S'

    # Microsoft Reserved Partition (16 MB)
    New-Partition -DiskNumber $vhd.Number -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null

    # Windows partition (rest of disk, NTFS)
    $win = New-Partition -DiskNumber $vhd.Number -UseMaximumSize -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
    Format-Volume -Partition $win -FileSystem NTFS -NewFileSystemLabel 'Windows' -Confirm:$false | Out-Null
    $win | Set-Partition -NewDriveLetter 'W'

    Write-Host "== Applying image (DISM /Apply-Image index $Index) to W:\ =="
    Expand-WindowsImage -ImagePath $SourceWim -Index $Index -ApplyPath 'W:\' | Out-Null

    # --- Optional: offline driver injection (default OFF) ---
    if ($InjectDrivers) {
        if (-not $DriverCabUrl) { throw 'InjectDrivers set but -DriverCabUrl is empty.' }
        $drvDir = Join-Path $env:TEMP ("winhwdrv-" + [System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $drvDir -Force | Out-Null
        $cab = Join-Path $drvDir 'drivers.cab'
        Write-Host "== Downloading driver cab: $DriverCabUrl =="
        Invoke-WebRequest -Uri $DriverCabUrl -OutFile $cab -UseBasicParsing
        Write-Host "== Expanding cab -> $drvDir =="
        & expand.exe -F:* "$cab" "$drvDir" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "expand.exe failed rc=$LASTEXITCODE" }
        Write-Host "== DISM /Add-Driver (recurse) -> W:\ =="
        & dism.exe /Image:W:\ /Add-Driver /Driver:"$drvDir" /Recurse
        if ($LASTEXITCODE -ne 0) { throw "DISM /Add-Driver failed rc=$LASTEXITCODE" }
    }

    Write-Host "== Injecting build-only unattend (WinRM + admin) into Panther =="
    $tmpl = Join-Path $PSScriptRoot 'unattend\unattend.xml.template'
    if (-not (Test-Path -LiteralPath $tmpl)) { throw "unattend template not found: $tmpl" }
    $xml = Get-Content -LiteralPath $tmpl -Raw
    $xml = $xml.Replace('@@WINRM_USER@@',     $WinRMUser)
    $xml = $xml.Replace('@@WINRM_PASSWORD@@', $WinRMPassword)
    $xml = $xml.Replace('@@COMPUTERNAME@@',   $ComputerName)
    $panther = 'W:\Windows\Panther'
    New-Item -ItemType Directory -Path $panther -Force | Out-Null
    # Write UTF-8 without BOM (Windows Setup is picky about the unattend encoding).
    [System.IO.File]::WriteAllText((Join-Path $panther 'unattend.xml'), $xml, (New-Object System.Text.UTF8Encoding($false)))

    Write-Host "== Writing UEFI boot files (bcdboot) =="
    $bcd = & "$env:SystemRoot\System32\bcdboot.exe" 'W:\Windows' '/s' 'S:' '/f' 'UEFI'
    if ($LASTEXITCODE -ne 0) { throw "bcdboot failed rc=$LASTEXITCODE`n$bcd" }
    Write-Host "  $bcd"

    Write-Host "== Success. Bootable base VHDX ready: $OutVhdx =="
}
catch {
    Write-Warning "prepare-base-vhdx failed: $($_.Exception.Message)"
    throw
}
finally {
    # Always dismount so the VHDX is not left attached.
    if ($vhd) {
        try { Dismount-VHD -Path $OutVhdx -ErrorAction SilentlyContinue } catch {}
    }
}
