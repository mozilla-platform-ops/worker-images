<#
.SYNOPSIS
  Ensure oscdimg.exe (ADK Deployment Tools) is available for the iso stage, served from
  OUR blob (resources/tools) rather than depending on the Microsoft ADK CDN at build time.

.DESCRIPTION
  create-iso.ps1 needs oscdimg to repackage a bootable ISO; DISM (native) can't. This
  guarantees oscdimg is present, in order of preference:
    1. Already installed (ADK default path or on PATH) -> nothing to do.
    2. Restore the cached Oscdimg folder from resources/tools/oscdimg/ (fast, fully self-contained).
    3. First-ever seed: pull resources/tools/adksetup.exe from our blob, install just
       OptionId.DeploymentTools, then CACHE the resulting Oscdimg folder back to
       resources/tools/oscdimg/ so every later build is served entirely from our blob.
  Only the one-time seed touches the Microsoft CDN (for the Deployment Tools payload);
  after that oscdimg lives in our blob. Runs on the build host (elevated; azcopy reuses
  the VM's az / managed-identity session set up by New-WinHwWim's `az login`).

.PARAMETER Account
  Storage account holding the tools (default hardwareimaging).
#>
[CmdletBinding()]
param(
    [string] $Account     = 'hardwareimaging',
    [string] $Container    = 'resources',
    [string] $ToolsPrefix  = 'tools'
)
$ErrorActionPreference = 'Stop'

# ADK installs oscdimg to this fixed location (Windows Kits\10 root is version-independent);
# it is exactly where create-iso.ps1 looks first.
$adkOscDir = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg'
$oscExe    = Join-Path $adkOscDir 'oscdimg.exe'

if ((Test-Path -LiteralPath $oscExe) -or (Get-Command oscdimg.exe -ErrorAction SilentlyContinue)) {
    Write-Host '== oscdimg already present =='
    return
}
if (-not (Get-Command azcopy -ErrorAction SilentlyContinue)) { throw 'azcopy not on PATH.' }
# azcopy has its own credential store; point it at the az CLI identity (the VM's managed identity).
if (-not $env:AZCOPY_AUTO_LOGIN_TYPE) { $env:AZCOPY_AUTO_LOGIN_TYPE = 'AZCLI' }
$baseUrl  = "https://$Account.blob.core.windows.net/$Container/$ToolsPrefix"
$cacheUrl = "$baseUrl/oscdimg"

# 1) Try the cached Oscdimg folder in our blob.
$stage = Join-Path $env:TEMP 'oscdimg-cache'
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
& azcopy copy "$cacheUrl/*" "$stage" --recursive 2>&1 | Out-Null   # no-op/err if the cache doesn't exist yet
if (Test-Path -LiteralPath (Join-Path $stage 'oscdimg.exe')) {
    Write-Host "== oscdimg: restoring from $Container/$ToolsPrefix/oscdimg (our blob) =="
    New-Item -ItemType Directory -Force -Path $adkOscDir | Out-Null
    Copy-Item (Join-Path $stage '*') $adkOscDir -Recurse -Force
    if (-not (Test-Path -LiteralPath $oscExe)) { throw "restore failed: $oscExe missing." }
    Write-Host "== oscdimg ready ($oscExe) =="
    return
}

# 2) Seed: install ADK Deployment Tools from our hosted adksetup.exe, then cache oscdimg back.
Write-Host "== oscdimg: seeding via $Container/$ToolsPrefix/adksetup.exe (one-time; payload from MS CDN) =="
$adkSetup = Join-Path $env:TEMP 'adksetup.exe'
& azcopy copy "$baseUrl/adksetup.exe" "$adkSetup" --overwrite=true
if ($LASTEXITCODE -ne 0) { throw "azcopy adksetup download failed rc=$LASTEXITCODE" }
$p = Start-Process -FilePath $adkSetup -ArgumentList '/quiet', '/features', 'OptionId.DeploymentTools', '/norestart', '/ceip', 'off' -Wait -PassThru
if ($p.ExitCode -notin 0, 3010) { throw "adksetup install failed rc=$($p.ExitCode)" }
if (-not (Test-Path -LiteralPath $oscExe)) { throw "oscdimg not found after ADK install ($oscExe)." }
Write-Host "== oscdimg: caching Oscdimg folder to $Container/$ToolsPrefix/oscdimg for future builds =="
& azcopy copy "$adkOscDir\*" "$cacheUrl" --recursive
if ($LASTEXITCODE -ne 0) { Write-Warning "azcopy cache upload failed rc=$LASTEXITCODE (non-fatal; oscdimg is installed locally for this build)." }
Write-Host "== oscdimg ready ($oscExe) =="
