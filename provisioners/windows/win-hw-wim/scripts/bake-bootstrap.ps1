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

# --- 5. Placeholder bake vault.yaml (secret-free) ---
# The bake role references NO Vault secrets (windows_worker_runner,
# hardware_observability, and windows_datacenter_administrator are all excluded — see
# ronin roles/win116424h2hwbake.pp), so this is an empty placeholder that just satisfies
# hiera's secrets/vault.yaml level. It contains no secrets and is scrubbed by
# sysprep-generalize.ps1 before capture. MUST be written WITHOUT a UTF-8 BOM — WinPS 5.1
# `Set-Content -Encoding utf8` emits a BOM, which the YAML parser rejects.
Step 'Writing placeholder bake vault.yaml'
$secretsDir = Join-Path $roninDir 'data\secrets'
New-Item -ItemType Directory -Path $secretsDir -Force | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $secretsDir 'vault.yaml'),
  "---`n# bake placeholder - no secrets; scrubbed before capture`n", $utf8NoBom)

# --- 6. Generate nodes.pp for the bake role ---
# WITHOUT a BOM: puppet's parser rejects a leading UTF-8 BOM ("Illegal UTF-8 Byte Order
# mark"), which is exactly what `Set-Content -Encoding utf8` produces on WinPS 5.1.
Step "Generating nodes.pp -> roles::$role"
$manifestDir = Join-Path $roninDir 'manifests\nodes'
New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $roninDir 'manifests\nodes.pp'),
  "node default {`n    include roles_profiles::roles::$role`n}`n", $utf8NoBom)

# --- 7. puppet apply AS SYSTEM (this is where the AppX removal + stable catalog bake) ---
# Puppet MUST run as NT AUTHORITY\SYSTEM. The bake role disables protected services
# (e.g. NgcCtnrSvc / Microsoft Passport Container) whose SCM handle an ordinary admin
# cannot open for write ("Access is denied", sc.exe rc=5) — only SYSTEM/TrustedInstaller
# can. Packer's WinRM session runs as the local 'packer' admin, so we relaunch the apply
# under a SYSTEM scheduled task, mirroring ronin .kitchen/provision_windows.ps1
# (Invoke-AsSystem) and production maintainsystem.ps1 (which runs puppet as SYSTEM).
#
# Use hiera.yaml (the role-aware config: has the roles/%{facts.custom_win_role}.yaml
# level that loads data/roles/<role>.yaml). win_hiera.yaml has NO roles/ level, so the
# role's win-worker.* data would not resolve.
Step 'Running puppet apply (bake catalog) as SYSTEM'
$puppetLog = Join-Path $log 'bake-puppet.log'
$sysScript = 'C:\bake\run-puppet-system.ps1'
$exitFile  = 'C:\bake\bake-puppet.exitcode'
Remove-Item $puppetLog, $exitFile -ErrorAction SilentlyContinue

# Child script executed by the SYSTEM task. Written BOM-less. A fresh SYSTEM process does
# not inherit this WinRM session's env, so it re-resolves PATH from the machine env,
# forwards the build-scoped GitHub token to the catalog (tooltool), and sets the role fact
# explicitly. Puppet writes to console; Tee-Object captures it to the shared log the parent
# tails (so output still streams into the packer/build log even if the VM is cleaned up).
$child = @"
`$ErrorActionPreference = 'Continue'
`$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine')
foreach (`$e in 'C:\Program Files\Puppet Labs\Puppet\bin','C:\Program Files\OpenVox\Puppet\bin','C:\Program Files\Git\cmd') { if (Test-Path `$e) { `$env:Path = `$e + ';' + `$env:Path } }
`$env:custom_win_github_pat = '$($env:custom_win_github_pat)'
`$env:FACTER_custom_win_role = '$role'
Set-Location '$roninDir'
& puppet apply manifests\nodes.pp --onetime --verbose --detailed-exitcodes --modulepath="modules;r10k_modules" --hiera_config=hiera.yaml --logdest console *>&1 | Tee-Object -FilePath '$puppetLog'
Set-Content -Path '$exitFile' -Value `$LASTEXITCODE
"@
[System.IO.File]::WriteAllText($sysScript, $child, $utf8NoBom)

# Stream new bytes of a growing log file to this console (so puppet output reaches the
# packer/build log live). Shared-read so it doesn't block the SYSTEM writer.
function Write-NewLog {
  param([string]$Path, [ref]$Offset)
  if (-not (Test-Path $Path)) { return }
  $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
  try {
    if ($fs.Length -lt $Offset.Value) { $Offset.Value = 0 }
    if ($fs.Length -eq $Offset.Value) { return }
    $fs.Seek($Offset.Value, 'Begin') | Out-Null
    $sr = New-Object System.IO.StreamReader($fs)
    try {
      $content = $sr.ReadToEnd()
      if ($content) { $content.TrimEnd("`r", "`n").Split(@("`r`n", "`n"), [System.StringSplitOptions]::None) | ForEach-Object { if ($_) { Write-Host $_ } } }
    } finally { $Offset.Value = $fs.Position; $sr.Dispose() }
  } finally { $fs.Dispose() }
}

$taskName  = 'BakePuppetAsSystem'
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$sysScript`""
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2)
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $taskName

# Wait for the SYSTEM task to record its exit code, tailing the puppet log meanwhile.
$deadline = (Get-Date).AddHours(2)
$offset = [long]0
while (-not (Test-Path $exitFile)) {
  if ((Get-Date) -gt $deadline) { throw 'Timed out waiting for the SYSTEM puppet-apply task.' }
  Write-NewLog -Path $puppetLog -Offset ([ref]$offset)
  Start-Sleep -Seconds 5
}
Write-NewLog -Path $puppetLog -Offset ([ref]$offset)   # flush the final chunk
$rc = [int]((Get-Content $exitFile -Raw).Trim())
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Stop-Transcript | Out-Null

# detailed-exitcodes: 0 = no changes, 2 = changes applied (both OK), 4/6 = failures.
# rc=1 = puppet failed to run/compile the catalog (not a resource-level failure).
if ($rc -eq 0 -or $rc -eq 2) {
  Write-Host "Bake puppet apply OK (rc=$rc)"

  # --- Remove the baked ronin clone so the DEPLOY re-clones fresh ---
  # Don't ship C:\ronin in the golden WIM. The deploy-time bootstrap (Get-Ronin) removes and
  # re-clones ronin anyway, so a baked copy is just stale weight pinned to this bake's hash;
  # dropping it forces a clean clone at the pool's current branch/hash on first boot (and keeps
  # the WIM smaller). The leftover HKLM\...\ronin_puppet registry values are a separate concern.
  if (Test-Path $roninDir) {
    Step "Removing baked ronin clone ($roninDir) so deploy re-clones fresh"
    Remove-Item $roninDir -Recurse -Force -ErrorAction SilentlyContinue
  }

  # --- 8. Bake OpenSSH server (mirrors Get-Bootstrap.ps1 Set-SSH) ---
  # Bake sshd + the audit key so SSH is up at FIRST BOOT, independent of the deploy-time
  # bootstrap. Makes the golden image self-sufficient and gives operator access even if
  # first-boot bootstrap stalls. Assets come from the same source Get-Bootstrap uses;
  # sysprep-generalize.ps1 removes ssh_host_* so host keys regenerate per node.
  Step 'Baking OpenSSH server + audit key'
  $sshAssets = 'https://raw.githubusercontent.com/mozilla-platform-ops/worker-images/main/provisioners/windows/MDC1Windows/ssh'
  $sshMsi = Join-Path $dlDir 'OpenSSH-Win64.msi'
  Get-PrereqFile -Urls @('https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.8.3.0p2-Preview/OpenSSH-Win64-v9.8.3.0.msi') -OutFile $sshMsi
  $s = Start-Process msiexec.exe -ArgumentList "/i `"$sshMsi`" /quiet /norestart ADDLOCAL=Server" -Wait -PassThru
  if ($s.ExitCode -ne 0 -and $s.ExitCode -ne 3010) { throw "OpenSSH MSI install failed rc=$($s.ExitCode)" }
  New-Item -ItemType Directory -Path 'C:\ProgramData\ssh' -Force | Out-Null
  Get-PrereqFile -Urls @("$sshAssets/sshd_config") -OutFile 'C:\ProgramData\ssh\sshd_config'
  $adminSsh = 'C:\Users\Administrator\.ssh'
  New-Item -ItemType Directory -Path $adminSsh -Force | Out-Null
  Get-PrereqFile -Urls @("$sshAssets/authorized_keys") -OutFile (Join-Path $adminSsh 'authorized_keys')

  # Also bake the audit key as an ADMIN-GROUP key. Win32-OpenSSH treats members of the
  # local Administrators group specially: with the "Match Group administrators" block
  # below it authenticates them ONLY against %ProgramData%\ssh\administrators_authorized_keys
  # (NOT the per-user .ssh\authorized_keys). Dropping the key there means ANY enabled admin
  # can SSH in with the key from first boot - notably the built-in Administrator, which
  # sysprep-generalize.ps1 enables so the deploy-time autologon works. That gives operator
  # access to diagnose a node even if the first-boot bootstrap stalls. (The build-only
  # 'packer' admin is disabled at the end of the bake, so it is not a usable path.)
  $adminKeys = 'C:\ProgramData\ssh\administrators_authorized_keys'
  Copy-Item (Join-Path $adminSsh 'authorized_keys') $adminKeys -Force
  # StrictModes: sshd IGNORES administrators_authorized_keys unless it is owned by an admin
  # and writable ONLY by Administrators/SYSTEM. Reset inheritance and grant those two alone.
  icacls $adminKeys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
  # Ensure the admin-group Match block is present (append once; idempotent across re-bakes).
  $sshdCfg = 'C:\ProgramData\ssh\sshd_config'
  if ((Get-Content $sshdCfg -Raw) -notmatch '(?im)^\s*Match\s+Group\s+administrators') {
    Add-Content -Path $sshdCfg -Value "`r`nMatch Group administrators`r`n       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys`r`n"
  }

  if (-not (Get-NetFirewallRule -Name 'AllowSSH' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'AllowSSH' -DisplayName 'Allow SSH' -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 | Out-Null
  }
  Set-Service -Name sshd -StartupType Automatic
  $mp = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  if ($mp -notlike '*OpenSSH*') { [Environment]::SetEnvironmentVariable('Path', "$mp;$env:ProgramFiles\OpenSSH", 'Machine') }

  # --- 9. Bake nxlog log shipping (mirrors Get-Bootstrap.ps1 / bootstrap.ps1 Set-Logging) ---
  # Install nxlog CE and drop the papertrail config + CA cert so the deployed worker ships
  # logs to papertrail from FIRST BOOT, instead of waiting for the deploy-time bootstrap to
  # do it. Same assets, same source blob ($extSrc = .../binaries/prerequisites) the upstream
  # Set-Logging uses, so behaviour matches a normally-bootstrapped node.
  Step 'Baking nxlog log shipping'
  $nxMsi  = 'nxlog-ce-2.10.2150.msi'
  $nxConf = 'nxlog.conf'
  $nxPem  = 'papertrail-bundle.pem'
  $nxDir  = "$env:SystemDrive\Program Files (x86)\nxlog"
  $nxMsiPath = Join-Path $dlDir $nxMsi
  Get-PrereqFile -Urls @("$extSrc/$nxMsi") -OutFile $nxMsiPath
  $nx = Start-Process msiexec.exe -ArgumentList "/i `"$nxMsiPath`" /passive /norestart" -Wait -PassThru
  if ($nx.ExitCode -ne 0 -and $nx.ExitCode -ne 3010) { throw "nxlog MSI install failed rc=$($nx.ExitCode)" }
  # msiexec /passive returns before the service dir is fully laid down; wait for conf\.
  for ($i = 0; $i -lt 30 -and -not (Test-Path "$nxDir\conf\"); $i++) { Start-Sleep 10 }
  if (-not (Test-Path "$nxDir\conf\")) { throw "nxlog conf dir never appeared at $nxDir\conf" }
  New-Item -ItemType Directory -Path "$nxDir\cert" -Force | Out-Null
  Get-PrereqFile -Urls @("$extSrc/$nxConf") -OutFile "$nxDir\conf\$nxConf"
  Get-PrereqFile -Urls @("$extSrc/$nxPem")  -OutFile "$nxDir\cert\$nxPem"
  # Leave nxlog Automatic so it starts on the deployed node; it will pick up the config
  # above on that boot. (No point starting it now - the bake VM's logs aren't wanted, and
  # sysprep/capture follow immediately.)
  Set-Service -Name nxlog -StartupType Automatic -ErrorAction SilentlyContinue

  # NOTE: the first-boot bootstrap runner (which launches Get-Bootstrap) is NOT baked
  # here. It is registered as a SYSTEM startup scheduled task at the very END of
  # sysprep-generalize.ps1 - after all bake work, immediately before Sysprep /shutdown -
  # so it can ONLY fire on the DEPLOYED node's first boot, never during the bake (the
  # bake VM has no further boots before capture). SetupComplete.cmd was tried here first
  # but did not run on the DISM/generalized boot; the startup task is the reliable path.
  exit $rc
}
Write-Host "----- bake-puppet.log (tail 120) -----"
Get-Content (Join-Path $log 'bake-puppet.log') -Tail 120 -ErrorAction SilentlyContinue
throw "Bake puppet apply FAILED rc=$rc"
