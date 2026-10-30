# Finalize through PowerShell Direct, then shut down for offline capture.
[CmdletBinding()]
param([bool] $PowerShellDirect = $false)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $PowerShellDirect) { throw 'Finalization must run through the host PowerShell Direct helper.' }
function Step($m) { Write-Host "== $m ==" }

# --- Secret + identity scrub ---
Step 'Scrubbing bake secrets and identity'
$buildSecretPaths = @("$env:SystemDrive\ronin\data\secrets\vault.yaml", "$env:SystemDrive\bake", "$env:SystemDrive\wim-bake")
foreach ($answerRoot in @("$env:SystemRoot\Panther", "$env:SystemRoot\System32\Sysprep")) {
  if (Test-Path -LiteralPath $answerRoot) {
    $buildSecretPaths += @(Get-ChildItem -LiteralPath $answerRoot -Recurse -File -Force -ErrorAction Stop |
      Where-Object { $_.Name -in @('unattend.xml', 'autounattend.xml') } |
      Select-Object -ExpandProperty FullName)
  }
}
foreach ($secretPath in $buildSecretPaths) {
  if (Test-Path -LiteralPath $secretPath) {
    Remove-Item -LiteralPath $secretPath -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $secretPath) { throw "Build secret cleanup failed: $secretPath" }
  }
}
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

# Keep the startup task until provisioning completes.
Step 'Baking first-boot bootstrap runner (RunDeployBootstrap startup task)'
$deployDir = 'C:\deploy'
New-Item -ItemType Directory -Path $deployDir -Force | Out-Null
$runner = @'
$ErrorActionPreference = 'Stop'
$log = 'C:\deploy\run-bootstrap.log'
function L($m) { ('{0} {1}' -f (Get-Date -Format o), $m) | Tee-Object -FilePath $log -Append | Out-Null }
try {
    $stage = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Mozilla\ronin_puppet' -ErrorAction SilentlyContinue
    if ($stage.bootstrap_stage -eq 'complete') {
        L 'bootstrap complete; removing startup task'
        Unregister-ScheduledTask -TaskName 'RunDeployBootstrap' -Confirm:$false
        return
    }
    $running = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
        $_.CommandLine -match '(?i)(?:^|\s)-file\s+"?(?:C:\\bootstrap\\bootstrap|D:\\scripts\\Get-Bootstrap)\.ps1"?(?:\s|$)'
    }
    if ($running) { L 'bootstrap already running; leaving startup task registered'; return }
    $gb = 'D:\scripts\Get-Bootstrap.ps1'
    for ($i = 0; $i -lt 60 -and -not (Test-Path $gb); $i++) { Start-Sleep -Seconds 10 }
    if (-not (Test-Path $gb)) { throw "$gb not found" }
    New-Item -ItemType Directory -Path 'C:\bootstrap' -Force | Out-Null
    if (Test-Path 'D:\secrets\vault.yaml') { Copy-Item 'D:\secrets\vault.yaml' 'C:\bootstrap\' -Force }
    powercfg -x -standby-timeout-ac 0
    powercfg -x -monitor-timeout-ac 0
    L 'launching Get-Bootstrap.ps1'
    $launcher = Start-Process -FilePath 'powershell.exe' -Wait -PassThru -NoNewWindow -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $gb
    )
    if ($launcher.ExitCode -ne 0) { throw "Get-Bootstrap failed: $($launcher.ExitCode)" }
    $stage = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Mozilla\ronin_puppet' -ErrorAction SilentlyContinue
    if ($stage.bootstrap_stage -ne 'complete') { throw 'bootstrap did not complete' }
    Unregister-ScheduledTask -TaskName 'RunDeployBootstrap' -Confirm:$false
}
catch {
    L ("bootstrap failed; retrying next boot: " + $_.Exception.Message)
    exit 1
}
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

Step 'Removing build-time WinRM access'
$policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WinRM\Service'
if (Test-Path -LiteralPath $policy) {
  foreach ($name in 'AllowBasic', 'AllowUnencryptedTraffic') {
    if ((Get-ItemProperty -LiteralPath $policy).PSObject.Properties[$name]) {
      Remove-ItemProperty -LiteralPath $policy -Name $name -ErrorAction Stop
    }
  }
}
$tokenPolicy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
if ((Test-Path -LiteralPath $tokenPolicy) -and
    (Get-ItemProperty -LiteralPath $tokenPolicy).PSObject.Properties['LocalAccountTokenFilterPolicy']) {
  Remove-ItemProperty -LiteralPath $tokenPolicy -Name LocalAccountTokenFilterPolicy -ErrorAction Stop
}
Set-Item WSMan:\localhost\Service\Auth\Basic -Value $false
Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $false
Get-ChildItem WSMan:\localhost\Listener -ErrorAction Stop | Remove-Item -Recurse -Force -ErrorAction Stop
if (@(Get-ChildItem WSMan:\localhost\Listener -ErrorAction Stop).Count) { throw 'WinRM listeners remain.' }
Get-NetFirewallRule -ErrorAction Stop | Where-Object DisplayName -eq 'WinRM-HTTP-In-5985' | Remove-NetFirewallRule -ErrorAction Stop
if (@(Get-NetFirewallRule -ErrorAction Stop | Where-Object DisplayName -eq 'WinRM-HTTP-In-5985').Count) {
  throw 'Build WinRM firewall rule remains.'
}
Set-Service WinRM -StartupType Disabled
Stop-Service WinRM -Force -ErrorAction Stop
$winrm = Get-CimInstance Win32_Service -Filter "Name='WinRM'" -ErrorAction Stop
if ($winrm.State -ne 'Stopped' -or $winrm.StartMode -ne 'Disabled') { throw 'WinRM is not stopped and disabled.' }

# The existing PowerShell Direct session retains its authenticated token.
Step 'Disabling build-only packer account'
$buildAcct = $env:USERNAME   # the account this provisioner runs under IS the build account
& net.exe user $buildAcct /active:no
if ($LASTEXITCODE -ne 0) { throw "Disabling build account failed: $LASTEXITCODE" }

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

if ('DefaultPassword' -in (Get-ItemProperty -LiteralPath $wl).PSObject.Properties.Name) {
  throw 'Build autologon password remains.'
}

Step 'Running Sysprep /generalize /oobe /quit'
$sp = "$env:SystemRoot\System32\Sysprep"
$process = Start-Process -FilePath (Join-Path $sp 'Sysprep.exe') -ArgumentList '/generalize', '/oobe', '/quit', '/quiet' -PassThru
if (-not $process.WaitForExit(1800000)) { throw 'Sysprep timed out.' }
if ($process.ExitCode -ne 0) { throw "Sysprep failed: $($process.ExitCode)" }
$state = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -Name ImageState).ImageState
if ($state -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { throw "Unexpected Sysprep image state: $state" }
& shutdown.exe /s /t 10 /f
if ($LASTEXITCODE -ne 0) { throw "Shutdown request failed: $LASTEXITCODE" }
Write-Output 'WIM_FINALIZE_OK'
