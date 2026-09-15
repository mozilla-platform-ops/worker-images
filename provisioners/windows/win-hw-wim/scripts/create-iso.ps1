<#
.SYNOPSIS
  Build a Windows 11 install ISO with the hardware-requirement checks bypassed
  (TPM 2.0 / Secure Boot / RAM / CPU / storage) so it can clean-install on
  unsupported hardware. SEPARATE from the ronin base WIMs - this only patches
  Windows Setup's compatibility gate; it does not bake any ronin/worker content.

.DESCRIPTION
  Mounts a base Win11 ISO, copies its contents to a writable working dir, injects an
  autounattend.xml at the media root whose windowsPE pass writes the
  HKLM\SYSTEM\Setup\LabConfig bypass keys (and MoSetup AllowUpgradesWithUnsupportedTPMOrCPU)
  BEFORE Setup's compatibility check, then repackages a UEFI+BIOS bootable ISO with
  oscdimg (Windows ADK Deployment Tools). Only the windowsPE pass is set, so after the
  bypass Setup continues as a normal (interactive) Win11 install - i.e. a stock ISO that
  also works on unsupported hardware. See https://woshub.com/upgrade-to-windows-11-unsupported-pc/.

  Runs on the Windows build host: needs the ADK (oscdimg) and elevation (Mount-DiskImage).

.PARAMETER SourceIso
  Path to the base Win11 ISO to patch.

.PARAMETER OutIso
  Path to write the requirement-bypass ISO. A "<OutIso>.sha256" sidecar is written too
  (so upload-wim.ps1 can publish both).

.PARAMETER Label
  Volume label for the output ISO. Default 'WIN11_NOCHK'.

.EXAMPLE
  .\create-iso.ps1 -SourceIso F:\iso\win11-24h2-base.iso -OutIso F:\iso\win11-24h2-nocheck.iso
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SourceIso,
    [Parameter(Mandatory)] [string] $OutIso,
    [string] $Label = 'WIN11_NOCHK',
    # Comma-delimited names of inject-library scripts (scripts/inject/<name>.ps1) to run against
    # the extracted media before repackaging (e.g. 'nocheck'). New-WinHwWim passes the config's
    # scripts: list. Each is invoked as <name>.ps1 -MediaDir <extracted media>.
    [string] $InjectScripts,
    [string] $InjectDir,
    # Optional offline driver injection into the ISO's boot.wim (Windows Setup, so it sees
    # storage/NIC during install) AND install.wim (every edition, so the installed OS has them).
    # '|'-delimited list of driver-pack URLs (.zip/.cab that expands to an .inf tree); e.g. the
    # HPE ProLiant DL360 Gen10 Windows driver pack. New-WinHwWim passes the config's drivers.cabs.
    [string] $DriverZips,
    # Storage account for azcopy AAD downloads of *.blob.core.windows.net driver packs.
    [string] $Account = 'hardwareimaging'
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $SourceIso)) { throw "SourceIso not found: $SourceIso" }

# --- Locate oscdimg (ADK Deployment Tools) --------------------------------------------
$oscExe = $null
$adkOsc = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
if (Test-Path -LiteralPath $adkOsc) {
    $oscExe = $adkOsc
}
else {
    $c = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
    if ($c) { $oscExe = $c.Source }
}
if (-not $oscExe) { throw 'oscdimg.exe not found - install the Windows ADK Deployment Tools.' }

# --- Working dir for the extracted media ----------------------------------------------
$outDir = [System.IO.Path]::GetDirectoryName($OutIso)
if (-not $outDir) { $outDir = (Get-Location).Path }
$work = Join-Path $outDir ('isobuild-' + [System.IO.Path]::GetFileNameWithoutExtension($OutIso))
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null

# --- Mount the source ISO and copy all contents out (ISO is read-only) -----------------
Write-Host "== Mounting $SourceIso =="
$mount = Mount-DiskImage -ImagePath $SourceIso -PassThru
try {
    $vol = ($mount | Get-Volume).DriveLetter
    if (-not $vol) { Start-Sleep -Seconds 2; $vol = ($mount | Get-Volume).DriveLetter }
    if (-not $vol) { throw 'Could not determine the mounted ISO drive letter.' }
    $src = "${vol}:\"
    Write-Host "== Copying media $src -> $work =="
    Copy-Item -Path (Join-Path $src '*') -Destination $work -Recurse -Force
}
finally {
    Dismount-DiskImage -ImagePath $SourceIso | Out-Null
}

# --- Run the configured inject-library scripts against the extracted media -------------
# Each name maps to scripts/inject/<name>.ps1 and is invoked as `<name>.ps1 -MediaDir <media>`
# to modify the media in place (e.g. 'nocheck' writes the requirement-bypass autounattend).
if (-not $InjectDir) { $InjectDir = Join-Path $PSScriptRoot 'inject' }
$names = @($InjectScripts -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($names.Count -eq 0) { Write-Warning 'No inject scripts specified (-InjectScripts); media left unmodified.' }
foreach ($n in $names) {
    if ($n -notmatch '^[A-Za-z0-9._-]+$') { throw "Illegal inject script name: '$n'" }
    $s = Join-Path $InjectDir "$n.ps1"
    if (-not (Test-Path -LiteralPath $s)) { throw "inject script not found: $s" }
    Write-Host "== inject: $n ($s) =="
    & $s -MediaDir $work
}

# --- Offline driver injection into the media WIMs (optional) ---------------------------
# Adds drivers so the installer sees storage/NIC (boot.wim = Windows Setup) and the
# installed OS has them (install.wim, every edition). DISM /Add-Driver /Recurse.
$drvUrls = @("$DriverZips" -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($drvUrls.Count -gt 0) {
    $drvRoot = Join-Path $work '_drivers'
    New-Item -ItemType Directory -Path $drvRoot -Force | Out-Null
    foreach ($u in $drvUrls) {
        $fn = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetFileName($u))
        Write-Host "== driver pack: $u =="
        if ($u -match '\.blob\.core\.windows\.net/') {
            if (-not $env:AZCOPY_AUTO_LOGIN_TYPE) { $env:AZCOPY_AUTO_LOGIN_TYPE = 'AZCLI' }
            & azcopy copy "$u" "$fn" --overwrite=true
            if ($LASTEXITCODE -ne 0) { throw "azcopy driver download failed rc=$LASTEXITCODE ($u)" }
        }
        else {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $u -OutFile $fn -UseBasicParsing
        }
        $dest = Join-Path $drvRoot ([System.IO.Path]::GetFileNameWithoutExtension($u))
        if ($fn -match '\.cab$') { New-Item -ItemType Directory -Path $dest -Force | Out-Null; & expand.exe $fn -F:* $dest | Out-Null }
        else { Expand-Archive -LiteralPath $fn -DestinationPath $dest -Force }
    }
    $mnt = Join-Path $work '_mnt'
    New-Item -ItemType Directory -Path $mnt -Force | Out-Null
    function Add-DriversToWim { param($Wim, $Index)
        (Get-Item -LiteralPath $Wim).IsReadOnly = $false   # media copied from read-only ISO
        Write-Host "== DISM /Add-Driver -> $(Split-Path -Leaf $Wim) index $Index =="
        & dism /Mount-Image /ImageFile:"$Wim" /Index:$Index /MountDir:"$mnt" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "DISM mount failed ($Wim idx $Index) rc=$LASTEXITCODE" }
        & dism /Image:"$mnt" /Add-Driver /Driver:"$drvRoot" /Recurse
        $addrc = $LASTEXITCODE
        & dism /Unmount-Image /MountDir:"$mnt" /Commit | Out-Null
        if ($LASTEXITCODE -ne 0) { & dism /Unmount-Image /MountDir:"$mnt" /Discard | Out-Null; throw "DISM commit failed ($Wim idx $Index)" }
        if ($addrc -ne 0) { Write-Warning "Add-Driver rc=$addrc on $(Split-Path -Leaf $Wim) idx $Index (some INFs may not apply)" }
    }
    # boot.wim index 2 = Windows Setup (needs storage/NIC to see the disk during install).
    $bootWim = Join-Path $work 'sources\boot.wim'
    if (Test-Path -LiteralPath $bootWim) { Add-DriversToWim $bootWim 2 }
    # install.wim = the OS image; inject into every edition index.
    $installWim = Join-Path $work 'sources\install.wim'
    if (Test-Path -LiteralPath $installWim) {
        foreach ($img in (Get-WindowsImage -ImagePath $installWim)) { Add-DriversToWim $installWim $img.ImageIndex }
    }
    else { Write-Warning "sources\install.wim not found (install.esd media?) - OS-image drivers not injected." }
    Remove-Item $drvRoot, $mnt -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "== driver injection done =="
}

# --- Repackage a UEFI(+BIOS) bootable ISO with oscdimg --------------------------------
$etfs = Join-Path $work 'boot\etfsboot.com'
$efisys = Join-Path $work 'efi\microsoft\boot\efisys.bin'
if (-not (Test-Path -LiteralPath $efisys)) { throw "efisys.bin not found ($efisys) - source is not a valid Windows ISO?" }
if (Test-Path -LiteralPath $etfs) {
    $bootdata = "-bootdata:2#p0,e,b$etfs#pEF,e,b$efisys"   # BIOS (etfsboot) + UEFI (efisys)
}
else {
    $bootdata = "-bootdata:1#pEF,e,b$efisys"               # UEFI-only (no etfsboot on this media)
}
if (Test-Path -LiteralPath $OutIso) { Remove-Item -LiteralPath $OutIso -Force }
Write-Host "== oscdimg -> $OutIso =="
& $oscExe '-m' '-o' '-u2' '-udfver102' "-l$Label" $bootdata "$work" "$OutIso"
if ($LASTEXITCODE -ne 0) { throw "oscdimg failed rc=$LASTEXITCODE" }

# --- sha256 sidecar (upload-wim.ps1 publishes <iso>.sha256 alongside) ------------------
$hash = (Get-FileHash -LiteralPath $OutIso -Algorithm SHA256).Hash.ToLower()
[System.IO.File]::WriteAllText("$OutIso.sha256", "$hash  $(Split-Path -Leaf $OutIso)", [System.Text.ASCIIEncoding]::new())
$sizeGb = [math]::Round((Get-Item -LiteralPath $OutIso).Length / 1GB, 2)
Write-Host "== Done: $OutIso ($sizeGb GB)  sha256=$hash =="

# --- Clean up the extracted media (large) ---------------------------------------------
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
