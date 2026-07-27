<#
.SYNOPSIS
  Build a golden Windows HW install.wim from a per-image YAML config. The scalable entry
  point for the wim-packer pipeline (one config = one WIM). Mirrors the
  worker-images bin/WorkerImages driver + config/*.yaml convention.

.DESCRIPTION
  Given -Image <name>, reads config/<name>.yaml (falling back to
  config/win-hw-wim-defaults.yaml for any field set to the string "default"),
  derives per-image namespaced names so many WIMs coexist, and runs the pipeline:

    prep    : download base WIM  -> prepare-base-vhdx -> register-base-vm
    build   : packer build (WU -> bake role -> sysprep -> capture)  -> <image>.wim
    publish : upload captured WIM (+ .sha256) to captured/<image>/

  Derived, per-image (from -Image and -BuildId):
    work dir   work/<image>/
    base WIM   work/<image>/<base.wim>          (from base/<base.wim>)
    VHDX       work/<image>/base.vhdx
    VM name    wim-bake-<image>
    build dir  work/<image>/build               (packer output_directory)
    golden WIM work/<image>/<image>-<buildid>.wim
    blob       captured/<image>/<image>-<buildid>.wim

  Auth: if AZ_CLIENT_ID / AZ_CLIENT_SECRET / AZ_TENANT are set, logs in as that
  SP; otherwise assumes an existing `az login` (a Relops member). Storage is
  Entra-only (no keys).

.PARAMETER Image
  Config basename under config/ (e.g. win11-24h2-hw).

.PARAMETER Stages
  Subset of prep,build,publish to run (default: all three, in order).

.PARAMETER WinRMPassword
  Password for the build-only WinRM account injected into the base VHDX.
  Auto-generated if not supplied (build-scoped; scrubbed before capture).

.PARAMETER BuildId
  Build identifier used in output names. Default: yyyyMMdd-HHmmss.

.PARAMETER KeepArtifacts
  Keep the per-image VM / VHDX / build dir after a successful run (default: clean up).

.EXAMPLE
  # Full build of the Win11 24H2 hw image:
  .\bin\WinHwWim\New-WinHwWim.ps1 -Image win11-24h2-hw

.EXAMPLE
  # Just re-publish an already-captured WIM:
  .\bin\WinHwWim\New-WinHwWim.ps1 -Image win11-24h2-hw -Stages publish -BuildId 20260723-101500
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Image,
    [ValidateSet('prep', 'build', 'publish')] [string[]] $Stages = @('prep', 'build', 'publish'),
    [string] $WinRMPassword,
    [string] $BuildId,
    # Client ID of the user-assigned managed identity to log in with on the build VM.
    # The VM is attached a USER-assigned identity (no system-assigned), so bare
    # `az login --identity` fails ("Please run az login") — it must be told which one.
    [string] $IdentityClientId,
    [switch] $KeepArtifacts
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Paths -------------------------------------------------------------------
$Root      = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path   # wim-packer/
$ConfigDir = Join-Path $Root 'config'
$ScriptDir = Join-Path $Root 'scripts'
$imgCfg    = Join-Path $ConfigDir "$Image.yaml"
$defCfg    = Join-Path $ConfigDir 'win-hw-wim-defaults.yaml'
foreach ($p in @($imgCfg, $defCfg)) { if (-not (Test-Path $p)) { throw "Config not found: $p" } }

# --- YAML ---------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Host '== Installing powershell-yaml module =='
    # Avoid the non-interactive NuGet-provider / PSGallery-trust prompt hang.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module powershell-yaml -Scope CurrentUser -Force -Confirm:$false
}
Import-Module powershell-yaml
$cfg = ConvertFrom-Yaml (Get-Content -Raw $imgCfg)
$def = ConvertFrom-Yaml (Get-Content -Raw $defCfg)

# Resolve a config value, falling back to the defaults file when it is "default"
# or absent. $Section/$Key index into both maps.
function Get-Val {
    param([string]$Section, [string]$Key)
    $v = $null
    if ($cfg.ContainsKey($Section) -and $cfg[$Section] -and $cfg[$Section].ContainsKey($Key)) { $v = $cfg[$Section][$Key] }
    if ($null -eq $v -or "$v" -eq 'default') {
        if ($def.ContainsKey($Section) -and $def[$Section] -and $def[$Section].ContainsKey($Key)) { $v = $def[$Section][$Key] }
    }
    return $v
}

if (-not $BuildId) { $BuildId = Get-Date -Format 'yyyyMMdd-HHmmss' }

# --- Resolved settings --------------------------------------------------------
$account   = $def['storage']['account']
$baseCont  = $def['storage']['base_container']
$capCont   = $def['storage']['captured_container']

$baseWim   = $cfg['base']['wim']
$edition   = $cfg['base']['edition']

# Robust bool: handles real YAML booleans AND quoted strings ("true"/"false").
$drvInject = ("$(Get-Val 'drivers' 'inject')".Trim() -match '^(true|1|yes)$')
$drvCabUrl = [string](Get-Val 'drivers' 'cab_url')

$roninOrg  = Get-Val 'ronin' 'org'
$roninRepo = Get-Val 'ronin' 'repo'
$roninBr   = $cfg['ronin']['branch']
$roninHash = if ($cfg['ronin'].ContainsKey('hash')) { [string]$cfg['ronin']['hash'] } else { '' }
$bakeRole  = $cfg['ronin']['bake_role']
$extSrc    = $def['ronin']['ext_src']

$puppetV   = Get-Val 'vm' 'puppet_version'
$gitV      = Get-Val 'vm' 'git_version'
$openvoxV  = Get-Val 'vm' 'openvox_version'
$cpus      = [int](Get-Val 'vm' 'cpus')
$memMb     = [int](Get-Val 'vm' 'memory_mb')
$switch    = Get-Val 'vm' 'switch_name'

# --- Validate required inputs (fail fast, before touching disks/Azure) ---------
if (-not $baseWim) { throw "config/$Image.yaml: base.wim is required." }
if (-not $edition) { throw "config/$Image.yaml: base.edition is required (the WIM edition name; empty would silently default to index 1)." }
if (-not $bakeRole) { throw "config/$Image.yaml: ronin.bake_role is required." }
if ($drvInject -and -not $drvCabUrl) { throw "config/$Image.yaml: drivers.inject is true but drivers.cab_url is empty." }

# --- Derived, per-image names -------------------------------------------------
$work      = Join-Path $Root "work\$Image"
$localBase = Join-Path $work $baseWim
$vhdx      = Join-Path $work 'base.vhdx'
$vmName    = "wim-bake-$Image"
$buildDir  = Join-Path $work 'build'
$goldenWim = Join-Path $work "$Image-$BuildId.wim"
$capBlob   = "$Image/$Image-$BuildId.wim"

New-Item -ItemType Directory -Path $work -Force | Out-Null

Write-Host "==================================================================="
Write-Host " Image      : $Image   (build $BuildId)"
Write-Host " Base WIM   : $baseCont/$baseWim  (edition '$edition')"
Write-Host " Bake role  : $bakeRole   ronin $roninOrg/$roninRepo@$roninBr"
Write-Host " Versions   : puppet $puppetV / git $gitV / openvox $openvoxV"
Write-Host " Output     : $goldenWim  ->  $capCont/$capBlob"
Write-Host " Stages     : $($Stages -join ', ')"
Write-Host "==================================================================="

# --- Auth: SP if creds present; else managed identity if nothing logged in ----
# azcopy reuses the az CLI identity (scripts set AZCOPY_AUTO_LOGIN_TYPE=AZCLI), so
# az must be logged in. On the build VM (headless) fall back to its managed identity.
if ($env:AZ_CLIENT_ID -and $env:AZ_CLIENT_SECRET -and $env:AZ_TENANT) {
    Write-Host '== az login (service principal) =='
    az login --service-principal -u $env:AZ_CLIENT_ID -p $env:AZ_CLIENT_SECRET --tenant $env:AZ_TENANT --only-show-errors | Out-Null
}
elseif (-not (az account show 2>$null)) {
    # The build VM has a USER-assigned identity (no system-assigned), so bare
    # `az login --identity` fails — pass the UAMI client id via --username.
    if ($IdentityClientId) {
        Write-Host "== az login (user-assigned managed identity $IdentityClientId) =="
        az login --identity --username $IdentityClientId --only-show-errors | Out-Null
    }
    else {
        Write-Host '== az login (managed identity) =='
        az login --identity --only-show-errors | Out-Null
    }
    if (-not (az account show 2>$null)) { throw 'az login (managed identity) failed — no active account.' }
}

$ps = { param($f, $a) & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ScriptDir $f) @a; if ($LASTEXITCODE) { throw "$f failed rc=$LASTEXITCODE" } }

# --- Stage: prep --------------------------------------------------------------
if ($Stages -contains 'prep') {
    Write-Host "`n### prep ########################################################"
    & $ps 'download-wim.ps1' @('-Blob', "$baseCont/$baseWim", '-Dest', $localBase, '-Account', $account)

    if (-not $WinRMPassword) {
        # Portable random password (avoid the Windows-only System.Web assembly).
        $WinRMPassword = 'Aa1!' + [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N').Substring(0, 12)
        Write-Host '  (generated a build-only WinRM password)'
    }
    if (Test-Path $vhdx) { Remove-Item $vhdx -Force }
    $prepArgs = @('-SourceWim', $localBase, '-OutVhdx', $vhdx, '-Edition', $edition, '-WinRMPassword', $WinRMPassword, '-ComputerName', 'nuc-bake')
    if ($drvInject) {
        Write-Host "  driver injection ON -> $drvCabUrl"
        $prepArgs += @('-InjectDrivers', '-DriverCabUrl', $drvCabUrl)
    }
    & $ps 'prepare-base-vhdx.ps1' $prepArgs

    if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) { Remove-VM -Name $vmName -Force }
    & $ps 'register-base-vm.ps1' @('-VmName', $vmName, '-Vhdx', $vhdx, '-SwitchName', $switch, '-Cpus', $cpus, '-MemoryStartupMB', $memMb)
}

# --- Stage: build -------------------------------------------------------------
if ($Stages -contains 'build') {
    Write-Host "`n### build #######################################################"
    if (-not $WinRMPassword) { throw 'build stage needs -WinRMPassword (the one used in prep).' }
    if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force }
    if (Test-Path $goldenWim) { Remove-Item $goldenWim -Force }

    # Per-image var-file (gitignored under work/). winrm_password is sensitive.
    $varFile = Join-Path $work 'build.pkrvars.hcl'
    @"
source_vm_name   = "$vmName"
switch_name      = "$switch"
winrm_username   = "packer"
winrm_password   = "$WinRMPassword"
cpus             = $cpus
memory_mb        = $memMb
ronin_org        = "$roninOrg"
ronin_repo       = "$roninRepo"
ronin_branch     = "$roninBr"
ronin_hash       = "$roninHash"
bake_role        = "$bakeRole"
puppet_version   = "$puppetV"
git_version      = "$gitV"
openvox_version  = "$openvoxV"
ronin_ext_src    = "$extSrc"
output_directory = "$($buildDir -replace '\\','/')"
output_wim       = "$($goldenWim -replace '\\','/')"
capture_name     = "$Image-$BuildId"
"@ | Set-Content -Path $varFile -Encoding utf8

    Push-Location $Root
    try {
        & packer init win-hw-wim.pkr.hcl; if ($LASTEXITCODE) { throw "packer init rc=$LASTEXITCODE" }
        & packer build -var-file="$varFile" win-hw-wim.pkr.hcl; if ($LASTEXITCODE) { throw "packer build rc=$LASTEXITCODE" }
    }
    finally { Pop-Location }
    if (-not (Test-Path $goldenWim)) { throw "build finished but golden WIM missing: $goldenWim" }
}

# --- Stage: publish -----------------------------------------------------------
if ($Stages -contains 'publish') {
    Write-Host "`n### publish #####################################################"
    if (-not (Test-Path $goldenWim)) { throw "no captured WIM to publish at $goldenWim (run build first, or pass the matching -BuildId)." }
    & $ps 'upload-wim.ps1' @('-Wim', $goldenWim, '-Container', $capCont, '-Account', $account, '-BlobName', $capBlob)
    Write-Host "== Published $capCont/$capBlob =="
}

# --- Cleanup ------------------------------------------------------------------
if (-not $KeepArtifacts -and ($Stages -contains 'build')) {
    Write-Host "`n== Cleanup (VM + VHDX + build dir; pass -KeepArtifacts to retain) =="
    if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) { Remove-VM -Name $vmName -Force }
    foreach ($p in @($vhdx, $buildDir)) { if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue } }
}

Write-Host "`n== DONE: $Image ($BuildId) =="
