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
    # Build-scoped GitHub token for puppet's tooltool download in the bake. Defaults to
    # $env:GITHUB_TOKEN / $env:PACKER_GITHUB_API_TOKEN (CI sets these). Empty is OK —
    # tooltool.py is public and downloads without a token. Not baked into the WIM.
    [string] $GithubPat = ($env:GITHUB_TOKEN, $env:PACKER_GITHUB_API_TOKEN, '' | Where-Object { $_ } | Select-Object -First 1),
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
# Robust bool (real YAML bool OR quoted string). Shared default is false.
$winUpdate = ("$(Get-Val 'vm' 'windows_update')".Trim() -match '^(true|1|yes)$')

# --- Validate required inputs (fail fast, before touching disks/Azure) ---------
if (-not $baseWim) { throw "config/$Image.yaml: base.wim is required." }
if (-not $edition) { throw "config/$Image.yaml: base.edition is required (the WIM edition name; empty would silently default to index 1)." }
if (-not $bakeRole) { throw "config/$Image.yaml: ronin.bake_role is required." }
if ($drvInject -and -not $drvCabUrl) { throw "config/$Image.yaml: drivers.inject is true but drivers.cab_url is empty." }

# --- Derived, per-image names -------------------------------------------------
# Large artifacts (base WIM ~5.6 GB, base VHDX, packer's clone/export, captured WIM)
# go on the big data disk (F:, 512 GB) when present — the C: OS disk (128 GB) is far
# too small to hold them all. bootstrap-build-host.ps1 formats F: as the data disk.
$workRoot  = if (Test-Path 'F:\') { 'F:\wim-work' } else { Join-Path $Root 'work' }
$work      = Join-Path $workRoot $Image
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
Write-Host " WindowsUpd : $(if ($winUpdate) { 'ON (full online patch pass)' } else { 'OFF (skipped)' })"
Write-Host " Output     : $goldenWim  ->  $capCont/$capBlob"
Write-Host " Stages     : $($Stages -join ', ')"
Write-Host "==================================================================="

# --- Auth: SP if creds present; else managed identity if nothing logged in ----
# azcopy reuses the az CLI identity (scripts set AZCOPY_AUTO_LOGIN_TYPE=AZCLI), so
# az must be logged in. On the build VM (headless) fall back to its managed identity.
#
# IMPORTANT: `az` writes routine diagnostics (incl. the "Please run 'az login'" notice)
# to stderr. Under this script's $ErrorActionPreference='Stop', WinPS 5.1 turns any
# native-command stderr into a TERMINATING NativeCommandError - even when redirected with
# 2>$null - so a harmless "am I logged in?" probe was aborting the whole build. Probe via
# exit code with the preference relaxed, and only hard-fail on a genuine login failure.
function Test-AzLoggedIn {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        az account show 1>$null 2>$null
        return ($LASTEXITCODE -eq 0)
    }
    finally { $ErrorActionPreference = $prev }
}

if ($env:AZ_CLIENT_ID -and $env:AZ_CLIENT_SECRET -and $env:AZ_TENANT) {
    Write-Host '== az login (service principal) =='
    $ErrorActionPreference = 'Continue'
    az login --service-principal -u $env:AZ_CLIENT_ID -p $env:AZ_CLIENT_SECRET --tenant $env:AZ_TENANT --only-show-errors | Out-Null
    $ErrorActionPreference = 'Stop'
    if (-not (Test-AzLoggedIn)) { throw 'az login (service principal) failed - no active account.' }
}
elseif (-not (Test-AzLoggedIn)) {
    # The build VM has a USER-assigned identity (no system-assigned), so bare
    # `az login --identity` fails - the UAMI client id must be passed explicitly
    # (az CLI >= 2.88 uses --client-id, not --username). Retry: on a freshly created
    # VM the identity/IMDS token endpoint can lag a bit behind first boot, and errors
    # are surfaced (not hidden) so a real failure is diagnosable in the build log.
    if (-not $IdentityClientId) {
        throw 'No active az session and no -IdentityClientId supplied; cannot authenticate on the build VM.'
    }
    Write-Host "== az login (user-assigned managed identity $IdentityClientId) =="
    $loggedIn = $false
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $ErrorActionPreference = 'Continue'
        $out = az login --identity --client-id $IdentityClientId 2>&1
        $rc = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($rc -eq 0 -and (Test-AzLoggedIn)) { $loggedIn = $true; break }
        Write-Warning "az login --identity attempt $attempt/6 failed (rc=$rc): $($out -join ' ')"
        Start-Sleep -Seconds 10
    }
    if (-not $loggedIn) { throw "az login (managed identity $IdentityClientId) failed after 6 attempts." }
    Write-Host '== az login OK =='
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
    # Packer builds the working VM (+ its RAM-sized memory file) under temp_path.
    $pkrTmp = Join-Path $work 'pkrtmp'
    New-Item -ItemType Directory -Path $pkrTmp -Force | Out-Null

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
github_pat       = "$GithubPat"
windows_update   = $($winUpdate.ToString().ToLower())
output_directory = "$($buildDir -replace '\\','/')"
temp_path        = "$($pkrTmp -replace '\\','/')"
output_wim       = "$($goldenWim -replace '\\','/')"
capture_name     = "$Image-$BuildId"
"@ | Set-Content -Path $varFile -Encoding utf8

    # --- Boot watchdog --------------------------------------------------------
    # EVERY guest-initiated reboot on this Gen2 clone lands as a full power-OFF, not a
    # soft reboot (nested-virt reboot behavior, observed 2026-07-28 on both the
    # post-specialize reboot AND the mid-bake windows-restart provisioners). Packer
    # never restarts a VM that powered itself off, so it hangs at "Waiting for WinRM"
    # / "Waiting for machine to restart". Run a background watchdog that (re)starts the
    # clone whenever it is Off, for the WHOLE build, UNTIL the sysprep provisioner
    # announces its intended /shutdown (the 'WIM-WATCHDOG-STOP' marker emitted at the
    # top of sysprep-generalize.ps1, streamed by Packer into $pkrLog). After that the
    # power-off is expected and Packer captures the VHDX, so the watchdog must NOT
    # restart it.
    $cloneVm = 'packer-nuc'   # hyperv builder default vm_name = packer-<source name 'nuc'>
    $pkrLog  = Join-Path $work 'packer-build.log'
    Remove-Item $pkrLog -Force -ErrorAction SilentlyContinue
    $watchdog = Start-Job -Name 'wim-boot-watchdog' -ScriptBlock {
        param($vm, $log)
        while ($true) {
            if ((Test-Path $log) -and (Select-String -Path $log -Pattern 'WIM-WATCHDOG-STOP' -SimpleMatch -Quiet)) { break }
            $v = Get-VM -Name $vm -ErrorAction SilentlyContinue
            if ($v -and $v.State -eq 'Off') { Start-VM -Name $vm -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 6
        }
    } -ArgumentList $cloneVm, $pkrLog

    Push-Location $Root
    try {
        # Pass the DIRECTORY (.), not a single file: `packer build foo.pkr.hcl` loads
        # only that file and ignores variables.pkr.hcl, so var.* declarations go missing.
        & packer init .; if ($LASTEXITCODE) { throw "packer init rc=$LASTEXITCODE" }
        # Tee Packer's output to $pkrLog so the watchdog can see the sysprep marker.
        # (Tee-Object is a cmdlet, so $LASTEXITCODE still reflects packer's exit code.)
        # -on-error=abort leaves the failed VM + dirs in place so the bake (esp. the
        # puppet apply) can be inspected / iterated via PowerShell Direct instead of a
        # ~40-min rebuild. Successful runs still clean up normally.
        & packer build -on-error=abort -var-file="$varFile" . 2>&1 | Tee-Object -FilePath $pkrLog
        if ($LASTEXITCODE) { throw "packer build rc=$LASTEXITCODE" }
    }
    finally {
        Pop-Location
        if ($watchdog) { Stop-Job $watchdog -ErrorAction SilentlyContinue; Remove-Job $watchdog -Force -ErrorAction SilentlyContinue }
    }
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
