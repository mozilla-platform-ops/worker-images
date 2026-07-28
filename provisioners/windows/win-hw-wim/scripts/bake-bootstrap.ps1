<#
.SYNOPSIS
  Step 3 (runs INSIDE the build VM via Packer): perform the ronin "bake".

.DESCRIPTION
  Reproduces the STABLE half of ronin's bootstrap.ps1: disable Windows Update /
  Store auto-update, install Git + Puppet/OpenVox, clone ronin at the pinned
  branch/hash, seed a BAKE registry identity, write a placeholder bake vault.yaml
  (only secrets referenced by BAKED profiles; no worker-registration secrets),
  generate nodes.pp for the bake role, and run `puppet apply`.

  The puppet run applies the bake role, which (via disable_services) performs the
  AppX removal ONCE here at bake time instead of on every NUC deploy.

  Inputs come from environment variables set by win-hw-wim.pkr.hcl:
    RONIN_ORG RONIN_REPO RONIN_BRANCH RONIN_HASH BAKE_ROLE
    PUPPET_VERSION GIT_VERSION OPENVOX_VERSION

  Exit code 2 from `puppet apply` (changes applied) is success; the Packer
  provisioner is configured with valid_exit_codes = [0, 2].
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$org      = $env:RONIN_ORG
$repo     = $env:RONIN_REPO
$branch   = $env:RONIN_BRANCH
$hash     = $env:RONIN_HASH
$role     = if ($env:BAKE_ROLE) { $env:BAKE_ROLE } else { 'win116424h2hwbake' }
$log      = 'C:\bake\logs'
$roninDir = 'C:\ronin'
New-Item -ItemType Directory -Path $log -Force | Out-Null
Start-Transcript -Path (Join-Path $log 'bake-bootstrap.log') -Append | Out-Null

function Step($m) { Write-Host "== $m ==" }

# --- 1. Stop Windows Update / Store fighting the AppX removal (root cause fix) ---
Step 'Disabling Windows Update + Store auto-update for the bake'
$wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item -Path $wu -Force | Out-Null
Set-ItemProperty -Path $wu -Name NoAutoUpdate -Value 1 -Type DWord
$store = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore'
New-Item -Path $store -Force | Out-Null
Set-ItemProperty -Path $store -Name AutoDownload -Value 2 -Type DWord
foreach ($svc in 'wuauserv','UsoSvc') {
  Stop-Service $svc -Force -ErrorAction SilentlyContinue
  Set-Service  $svc -StartupType Disabled -ErrorAction SilentlyContinue
}

# --- 2. Install Git + Puppet/OpenVox (versions pinned to the hw pool) ---
# Prerequisite installers come from ronin's public assets blob under
# /binaries/prerequisites — the SAME source worker-images MDC1Windows/bootstrap.ps1
# uses (Get-PreRequ). Versions are pinned in the pkrvars to match
# worker-images config/windows_production_defaults.yaml.
$extSrc  = if ($env:RONIN_EXT_SRC) { $env:RONIN_EXT_SRC } else { 'https://roninpuppetassets.blob.core.windows.net/binaries/prerequisites' }
$dlDir   = 'C:\bake\prereq'
New-Item -ItemType Directory -Path $dlDir -Force | Out-Null

function Get-PrereqFile {
  param([string[]]$Urls, [string]$OutFile)
  foreach ($u in $Urls) {
    try {
      Write-Host "  downloading $u"
      Invoke-WebRequest -Uri $u -OutFile $OutFile -UseBasicParsing
      if (Test-Path $OutFile) { return }
    } catch { Write-Warning "  failed $u : $($_.Exception.Message)" }
  }
  throw "could not download any of: $($Urls -join ', ')"
}

# Puppet vs OpenVox: mirror Get-PreRequ — if OPENVOX_VERSION is set it wins.
if ($env:OPENVOX_VERSION) {
  $agentMsi = "openvox-agent-$($env:OPENVOX_VERSION)-x64.msi"
} else {
  $agentMsi = "puppet-agent-$($env:PUPPET_VERSION)-x64.msi"
}
$gitExe = "Git-$($env:GIT_VERSION)-64-bit.exe"

Step "Installing agent ($agentMsi) and Git ($gitExe) from $extSrc"

# Puppet/OpenVox agent (MSI) — assets blob only.
$agentPath = Join-Path $dlDir $agentMsi
Get-PrereqFile -Urls @("$extSrc/$agentMsi") -OutFile $agentPath
$p = Start-Process msiexec.exe -ArgumentList "/i `"$agentPath`" /qn /norestart" -Wait -PassThru
if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "agent MSI install failed rc=$($p.ExitCode)" }

# Git — prefer the assets-blob mirror, fall back to the git-for-windows upstream
# (upstream needs no PAT for a public release asset).
$gitPath    = Join-Path $dlDir $gitExe
$gitUpstream = "https://github.com/git-for-windows/git/releases/download/v$($env:GIT_VERSION).windows.1/$gitExe"
Get-PrereqFile -Urls @("$extSrc/$gitExe", $gitUpstream) -OutFile $gitPath
$p = Start-Process $gitPath -ArgumentList '/VERYSILENT /NORESTART /SUPPRESSMSGBOXES /NOCANCEL' -Wait -PassThru
if ($p.ExitCode -ne 0) { throw "Git install failed rc=$($p.ExitCode)" }

# Refresh PATH in this session so `puppet` / `git` resolve for the steps below.
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
foreach ($extra in 'C:\Program Files\Puppet Labs\Puppet\bin','C:\Program Files\OpenVox\Puppet\bin','C:\Program Files\Git\cmd') {
  if ((Test-Path $extra) -and ($env:Path -notlike "*$extra*")) { $env:Path += ";$extra" }
}
if (-not (Get-Command puppet -ErrorAction SilentlyContinue)) { throw 'puppet not on PATH after install' }
if (-not (Get-Command git    -ErrorAction SilentlyContinue)) { throw 'git not on PATH after install' }

# --- 3. Clone ronin at the pinned branch/hash ---
Step "Cloning $org/$repo@$branch"
if (Test-Path $roninDir) { Remove-Item $roninDir -Recurse -Force }
& git clone --single-branch --branch $branch "https://github.com/$org/$repo.git" $roninDir
if ($LASTEXITCODE -ne 0) { throw "git clone failed rc=$LASTEXITCODE" }
if ($hash) {
  Push-Location $roninDir; & git checkout $hash; if ($LASTEXITCODE -ne 0) { Pop-Location; throw "checkout $hash failed" }; Pop-Location
}
& git config --global --add safe.directory $roninDir

# --- 4. Seed BAKE registry identity (generic, no pool/worker secrets) ---
Step 'Seeding bake registry identity'
$ron = 'HKLM:\SOFTWARE\Mozilla\ronin_puppet'
New-Item -Path $ron -Force | Out-Null
Set-ItemProperty -Path $ron -Name role            -Value $role -Type String
Set-ItemProperty -Path $ron -Name workerType      -Value $role -Type String   # drives win_hiera lookup
Set-ItemProperty -Path $ron -Name worker_pool_id  -Value 'bake' -Type String
Set-ItemProperty -Path $ron -Name image_provisioner -Value 'wim-packer' -Type String
Set-ItemProperty -Path $ron -Name bootstrap_stage -Value 'inprogress' -Type String

# --- 5. Placeholder bake vault.yaml (only secrets referenced by BAKED profiles) ---
# No worker-registration secrets are baked (windows_worker_runner is excluded from
# the bake role). marlin_pw is referenced by hardware_observability; a non-functional
# placeholder satisfies the lookup and is scrubbed by sysprep-generalize.ps1.
Step 'Writing placeholder bake vault.yaml'
$secretsDir = Join-Path $roninDir 'data\secrets'
New-Item -ItemType Directory -Path $secretsDir -Force | Out-Null
@'
---
marlin_pw: "bake-placeholder-scrubbed-before-capture"
'@ | Set-Content -Path (Join-Path $secretsDir 'vault.yaml') -Encoding utf8

# --- 6. Generate nodes.pp for the bake role ---
Step "Generating nodes.pp -> roles::$role"
$manifestDir = Join-Path $roninDir 'manifests\nodes'
New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
"node default {`n    include roles_profiles::roles::$role`n}" |
  Set-Content -Path (Join-Path $roninDir 'manifests\nodes.pp') -Encoding utf8

# --- 7. puppet apply (this is where the AppX removal + stable catalog bake) ---
Step 'Running puppet apply (bake catalog)'
Push-Location $roninDir
# Log to BOTH the console (so puppet output streams into the packer/build log and is
# visible even if the VM is later cleaned up) and a file (for on-box inspection).
& puppet apply manifests\nodes.pp --onetime --verbose --detailed-exitcodes `
    --modulepath="modules;r10k_modules" --hiera_config=win_hiera.yaml `
    --logdest console --logdest (Join-Path $log 'bake-puppet.log')
$rc = $LASTEXITCODE
Pop-Location
Stop-Transcript | Out-Null

# detailed-exitcodes: 0 = no changes, 2 = changes applied (both OK), 4/6 = failures.
# rc=1 = puppet failed to run/compile the catalog (not a resource-level failure).
if ($rc -eq 0 -or $rc -eq 2) { Write-Host "Bake puppet apply OK (rc=$rc)"; exit $rc }
Write-Host "----- bake-puppet.log (tail 120) -----"
Get-Content (Join-Path $log 'bake-puppet.log') -Tail 120 -ErrorAction SilentlyContinue
throw "Bake puppet apply FAILED rc=$rc"
