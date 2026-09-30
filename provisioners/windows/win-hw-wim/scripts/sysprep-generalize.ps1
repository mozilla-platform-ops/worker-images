<#
.SYNOPSIS
  Step 4 (runs INSIDE the build VM via Packer): scrub machine-specific state,
  then Sysprep /generalize /oobe /shutdown so the disk can be captured clean.

.DESCRIPTION
  Removes everything that must NOT ship in a generalized golden image:
    - the placeholder bake vault.yaml (secret hygiene)
    - the bake registry identity (role/workerType/worker_pool_id) so first boot
      re-seeds real values; leaves bootstrap_stage = 'setup' so deploy bootstraps
    - SSH host keys and any generic-worker keys (none baked, defensive)
    - build-only autologon
  Then runs Sysprep. The classic Win11 failure here is per-user AppX left behind,
  so we assert none remain (the bake removed provisioned packages) and surface
  Panther logs on failure.

  IMPORTANT: capture must happen AFTER this scrub (it does — capture is a
  post-build step in win-hw-wim.pkr.hcl).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Step($m) { Write-Host "== $m ==" }

# Signal the host-side boot watchdog (New-WinHwWim.ps1) to STOP restarting the guest:
# from here we deliberately Sysprep /shutdown, and that power-off is what Packer waits
# for to capture the VHDX. Write-Output (not Write-Host) so it reaches Packer's captured
# stdout stream and lands in packer-build.log where the watchdog greps for it.
Write-Output 'WIM-WATCHDOG-STOP: sysprep starting; the guest power-off from here is expected (capture).'

# --- Secret + identity scrub ---
Step 'Scrubbing bake secrets and identity'
Remove-Item 'C:\ronin\data\secrets\vault.yaml' -Force -ErrorAction SilentlyContinue
# Remove the whole bake work dir. It holds the SYSTEM puppet-apply helper
# (C:\bake\run-puppet-system.ps1) which EMBEDS the build-scoped GitHub token
# (custom_win_github_pat) when one is supplied, plus prereq installers and puppet logs.
# None of it belongs in the golden WIM — drop it before capture.
Remove-Item 'C:\bake' -Recurse -Force -ErrorAction SilentlyContinue
$ron = 'HKLM:\SOFTWARE\Mozilla\ronin_puppet'
if (Test-Path $ron) {
  foreach ($v in 'role','workerType','worker_pool_id','GITHASH','secret_date') {
    Remove-ItemProperty -Path $ron -Name $v -ErrorAction SilentlyContinue
  }
  # Leave a clean state so the deploy-time bootstrap runs.
  Set-ItemProperty -Path $ron -Name bootstrap_stage -Value 'setup' -Type String
  Set-ItemProperty -Path $ron -Name hand_off_ready  -Value 'no'    -Type String
}

# --- SSH host keys (regenerated at first boot) ---
Step 'Removing SSH host keys'
Remove-Item 'C:\ProgramData\ssh\ssh_host_*' -Force -ErrorAction SilentlyContinue

# --- Disable the build-only autologon ---
Step 'Disabling autologon'
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $wl -Name AutoAdminLogon -Value '0' -ErrorAction SilentlyContinue
Remove-ItemProperty -Path $wl -Name DefaultPassword -ErrorAction SilentlyContinue

# --- Enable the built-in Administrator so the DEPLOY-time autologon works ---
# The whole first-boot kickoff on the deployed node runs through the production
# base-autounattend.xml oobeSystem pass: <AutoLogon> logs in Administrator ONCE
# (LogonCount=1) and <FirstLogonCommands> - which run only inside that interactive
# logon - seed C:\bootstrap + vault.yaml and launch Get-Bootstrap.ps1 (whose final
# `psexec -i` also needs that interactive session). OS-deploy.ps1 already stages that
# unattend to \Windows\Panther and substitutes the real Administrator password
# (win_adminpw) into it. BUT the built-in Administrator is DISABLED by default and this
# bake ran as the 'packer' account, so it was never enabled - the deploy autologon then
# fails and the node sits at the login screen (nuc13-160's "packer login"), FirstLogonCommands
# never fire, and nothing bootstraps. Enable it here so the deploy autologon can take.
# (No password is set in the image; oobeSystem sets it to win_adminpw before any logon.)
Step 'Enabling built-in Administrator for deploy-time autologon'
& net.exe user Administrator /active:yes
if ($LASTEXITCODE -ne 0) { Write-Warning "net user Administrator /active:yes returned $LASTEXITCODE" }

# --- Remove the build-only first-logon network helper ---
# set-bake-network.ps1 (dropped by prepare-base-vhdx.ps1 and invoked by the build
# unattend's FirstLogonCommands) is build-only. It is inert in a deployed image (a
# bare .ps1 in Setup\Scripts is not auto-run; only SetupComplete.cmd is), but it must
# not ship in the golden WIM. Also drop its log.
Step 'Removing build-only network helper'
Remove-Item 'C:\Windows\Setup\Scripts\set-bake-network.ps1' -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Windows\Temp\bake-network.log' -Force -ErrorAction SilentlyContinue
# The helper self-registers a SYSTEM 'BakeNetwork' startup task (re-asserts network/WinRM
# on every boot so mid-bake restarts don't strand Packer). Build-only - unregister it so
# it never ships in the golden WIM.
Unregister-ScheduledTask -TaskName 'BakeNetwork' -Confirm:$false -ErrorAction SilentlyContinue

# NOTE: there is deliberately no pre-Sysprep leftover-AppX enumeration here. The bake
# disables AppXSvc (win_disable_services::disable_appxsvc), and Get-AppxPackage needs that
# service, so any such check post-bake can only ever fail/no-op. If a per-user AppX
# Sysprep blocker is ever suspected, check it inside bake-bootstrap.ps1 (right after
# puppet apply) where AppXSvc is still running.

# --- Bake the first-boot bootstrap runner (SYSTEM startup task) ---
# Registered HERE, as the last thing before Sysprep, so it CANNOT run during the bake:
# the bake VM only ever shuts down from this point (no more boots before capture). On the
# DEPLOYED node's first boot it reproduces the shape the unattend FirstLogonCommands would
# have (seed C:\bootstrap + vault.yaml, disable sleep) and launches Get-Bootstrap.ps1
# (which OS-deploy.ps1 stages on D:\ with the pool params already substituted). One-shot:
# it flags + unregisters itself once it has launched Get-Bootstrap, so it does not re-run
# on later ronin reboots (matches the production one-shot FirstLogonCommands launcher).
Step 'Baking first-boot bootstrap runner (RunDeployBootstrap startup task)'
$deployDir = 'C:\deploy'
New-Item -ItemType Directory -Path $deployDir -Force | Out-Null
$runner = @'
$ErrorActionPreference = 'Continue'
$log = 'C:\deploy\run-bootstrap.log'
function L($m) { ('{0} {1}' -f (Get-Date -Format o), $m) | Tee-Object -FilePath $log -Append | Out-Null }
$flag = 'C:\deploy\.bootstrap-launched'
if (Test-Path $flag) {
    L 'bootstrap already launched on a prior boot; unregistering task and exiting'
    Unregister-ScheduledTask -TaskName 'RunDeployBootstrap' -Confirm:$false -ErrorAction SilentlyContinue
    return
}
L 'run-bootstrap: start'
# OS-deploy.ps1 stages Get-Bootstrap.ps1 (templated with the pool params) to D:\scripts in
# WinPE before this boot; wait for D: to mount and the script to appear.
$gb = 'D:\scripts\Get-Bootstrap.ps1'
for ($i = 0; $i -lt 60 -and -not (Test-Path $gb); $i++) { Start-Sleep -Seconds 10 }
if (-not (Test-Path $gb)) { L "ERROR: $gb not found; leaving task registered to retry next boot"; return }
# FirstLogonCommands-equivalent prerequisites (base-autounattend.xml oobeSystem pass):
if (-not (Test-Path 'C:\bootstrap')) { New-Item -ItemType Directory -Path 'C:\bootstrap' -Force | Out-Null }
if (Test-Path 'D:\secrets\vault.yaml') { Copy-Item 'D:\secrets\vault.yaml' 'C:\bootstrap\' -Force }
powercfg -x -standby-timeout-ac 0 2>$null
powercfg -x -monitor-timeout-ac 0 2>$null
L 'run-bootstrap: launching Get-Bootstrap.ps1'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $gb *>&1 | Tee-Object -FilePath $log -Append
L ('run-bootstrap: Get-Bootstrap returned rc=' + $LASTEXITCODE)
# Mark launched + one-shot self-remove; bootstrap.ps1 continues via ronin's own task.
New-Item -Path $flag -ItemType File -Force | Out-Null
Unregister-ScheduledTask -TaskName 'RunDeployBootstrap' -Confirm:$false -ErrorAction SilentlyContinue
'@
$utf8NoBomRunner = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $deployDir 'run-bootstrap.ps1'), $runner, $utf8NoBomRunner)
$rdbAction    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\deploy\run-bootstrap.ps1'
$rdbTrigger   = New-ScheduledTaskTrigger -AtStartup
try { $rdbTrigger.Delay = 'PT2M' } catch { }   # best-effort boot delay; wrapper also waits for D:/network
$rdbPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$rdbSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 3)
Register-ScheduledTask -TaskName 'RunDeployBootstrap' -Action $rdbAction -Trigger $rdbTrigger -Principal $rdbPrincipal -Settings $rdbSettings -Force | Out-Null
Write-Host '  RunDeployBootstrap SYSTEM startup task registered (fires only on the deployed node).'

# --- Bake hygiene: neutralize the build-only 'packer' admin account ([[bake-hygiene-todo]]) ---
# The build unattend created an Administrators-group account (@@WINRM_USER@@, i.e. 'packer')
# for Packer/WinRM. It must not remain a usable admin in the golden WIM. We DISABLE it rather
# than delete it: this script runs AS that account (over WinRM), and you cannot delete the
# account you are currently logged in as. Disabling fully neutralizes it - a disabled account
# cannot log in locally, over WinRM, or via SSH - which is the security goal. (Deletion, if
# ever wanted, must happen as SYSTEM on the deployed node where packer isn't logged in.)
# This is the LAST WinRM-affecting step before Sysprep /shutdown; no provisioner runs after it.
Step 'Disabling build-only packer account'
$buildAcct = $env:USERNAME   # the account this provisioner runs under IS the build account
& net.exe user $buildAcct /active:no
if ($LASTEXITCODE -ne 0) { Write-Warning "net user $buildAcct /active:no returned $LASTEXITCODE" }

# Clear any autologon the bake configured. The build 'packer' account auto-logs in during the bake,
# leaving AutoAdminLogon/DefaultUserName/DefaultPassword/AutoLogonSID in Winlogon. Left in the golden
# image these collide with the deploy-time Administrator autologon and generic-worker's task-user
# autologon (observed on nuc13-160/024: AutoLogonSID still pointed at the baked packer account, and the
# task user never logged in). Scrub them so the deployed node starts with no baked autologon.
Step 'Clearing baked autologon (Winlogon) keys'
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $wl -Name 'AutoAdminLogon' -Value '0' -Force
foreach ($v in 'DefaultUserName', 'DefaultPassword', 'DefaultDomainName', 'AutoLogonSID', 'AutoLogonCount') {
  Remove-ItemProperty -Path $wl -Name $v -ErrorAction SilentlyContinue
}

# --- Sysprep generalize + shutdown ---
Step 'Running Sysprep /generalize /oobe /shutdown'
$sp = "$env:SystemRoot\System32\Sysprep"
Remove-Item (Join-Path $sp 'unattend.xml') -Force -ErrorAction SilentlyContinue
& (Join-Path $sp 'Sysprep.exe') /generalize /oobe /shutdown /quiet
if ($LASTEXITCODE -ne 0) {
  Write-Warning "Sysprep returned rc=$LASTEXITCODE - dumping Panther errors:"
  Get-Content (Join-Path $sp 'Panther\setuperr.log') -ErrorAction SilentlyContinue | Select-Object -Last 40
  throw "Sysprep failed rc=$LASTEXITCODE"
}
# On success the VM powers off; Packer finalizes the artifact.
