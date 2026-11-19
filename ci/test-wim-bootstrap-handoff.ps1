$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Read-Ast($Path) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    return $ast
}
$deployRoot = Join-Path $root 'provisioners/windows/MDC1Windows'
$deploy = Read-Ast (Join-Path $deployRoot 'OS-deploy.ps1')
foreach ($name in 'Get-DeploymentPool', 'Read-DeploymentSecrets', 'Update-GetBoot') {
    $definition = $deploy.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
}
. (Join-Path $root 'bin/WorkerImages/Public/ConvertFrom-Yaml.ps1')
$inventory = ConvertFrom-Yaml (Get-Content (Join-Path $deployRoot 'pools.yml') -Raw)
foreach ($node in $inventory['Known-BAD'].Values | ForEach-Object { $_ }) {
    $fallback = Get-DeploymentPool $inventory $node
    $family = $node -replace '-[0-9]+$'
    if ($fallback.Pool.name -ne $inventory.defaults.recovery_pools_by_prefix[$family] -or
        $fallback.SkipReason -notmatch 'Known-BAD') {
        throw "Known-BAD node $node did not select OS-only deployment for its hardware family."
    }
}
foreach ($case in @(
    @{ node = 'nuc13-001'; pool = 'win11-64-24h2-hw'; skip = $false },
    @{ node = 'nuc13-01'; pool = 'win11-64-24h2-hw'; skip = $true },
    @{ node = 't-nuc12-999'; pool = 'win11-64-24h2-hw-ref'; skip = $true },
    @{ node = ''; pool = 'win11-64-24h2-hw'; skip = $true },
    @{ node = ''; override = 'win11-64-24h2-hw-ref'; pool = 'win11-64-24h2-hw-ref'; skip = $true }
)) {
    $selection = Get-DeploymentPool $inventory $case.node $case.override
    if ($selection.Pool.name -ne $case.pool -or [bool]$selection.SkipReason -ne $case.skip) {
        throw "Unexpected deployment mode or pool for '$($case.node)'."
    }
}

# Exercise the deploy-time decision and the rendered handoff, without accessing a share.
$preflight = $deploy.Find({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
    $node.Extent.Text.StartsWith('if (-not $bootstrapSkipReason -and -not ($pool.ronin')
}, $true)
$answerFileRecovery = $deploy.Find({
    param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
    $node.Extent.Text.Contains('$recoveryCommand = ')
}, $true)
$local_scripts = 'D:\scripts\'
$template = Get-Content (Join-Path $deployRoot 'Get-Bootstrap.ps1') -Raw
$answerFile = Get-Content (Join-Path $deployRoot 'base-autounattend.xml') -Raw
function Test-DeployMode {
    param([string]$NodeName, [string]$PoolSecrets, [string]$Token, [string]$ExpectedPool, [string]$ExpectedSkipReason)
    $YAML = $inventory
    $shortname = $NodeName
    $pool = (Get-DeploymentPool $inventory $shortname).Pool
    $secret_file_name = "$($pool.name)-$($pool.secret_date).yaml"
    $source_secrets = "Z:\secrets\$secret_file_name"
    function Get-Content {
        param($Path, $LiteralPath, [switch]$Raw, $Encoding, $ErrorAction)
        if ($LiteralPath -eq $source_secrets) {
            if (-not $PoolSecrets) { throw 'Missing file' }
            return $PoolSecrets
        }
        return $template
    }
    function Test-Path { return $false }
    function Invoke-DownloadWithRetry { }
    function Set-Content { param($Path, $Value, $ErrorAction) $script:rendered = $Value }
    $workerImagesPAT = $Token
    $bootstrapSkipReason = ''
    . ([scriptblock]::Create($preflight.Extent.Text))
    if ($pool.name -ne $ExpectedPool -or $bootstrapSkipReason -ne $ExpectedSkipReason) {
        throw "$NodeName selected $($pool.name) with bootstrap decision '$bootstrapSkipReason'."
    }
    if (-not $ExpectedSkipReason -and ($deploymentSecrets.Yaml -ne $PoolSecrets -or $deploymentSecrets.AdminPassword -ne 'test-only-password')) {
        throw 'Normal deployment lost the validated secrets snapshot.'
    }
    $WorkerPool = $pool.name
    $secret_date = $pool.secret_date
    Update-GetBoot -revision ('a' * 40) 6>$null | Out-Null
    $rendered = [scriptblock]::Create($script:rendered).Ast
    $reason = $rendered.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $_.Left.Extent.Text -eq '$bootstrapSkipReason'
    }
    . ([scriptblock]::Create($reason.Extent.Text))
    if ($bootstrapSkipReason -ne $ExpectedSkipReason) { throw 'Launcher lost its deployment mode.' }

    [xml]$unattendXml = $answerFile
    if ($bootstrapSkipReason) {
        . ([scriptblock]::Create($answerFileRecovery.Extent.Text))
        $task = $unattendXml.SelectSingleNode("//*[local-name()='settings' and @pass='specialize']//*[local-name()='Path' and contains(text(),'ConfigureRecoverySSH')]")
        if (-not $task -or $task.InnerText -notmatch 'D:\\scripts\\Get-Bootstrap\.ps1' -or
            $unattendXml.SelectSingleNode("//*[local-name()='AutoLogon' or local-name()='FirstLogonCommands']")) {
            throw 'Recovery answer file must schedule SSH without first-logon bootstrap.'
        }
    }
    elseif (-not $unattendXml.SelectSingleNode("//*[local-name()='CommandLine' and contains(text(),'Get-Bootstrap.ps1')]")) {
        throw 'Normal answer file lost its first-logon bootstrap.'
    }
}
Test-DeployMode 'nuc13-018' 'win_adminpw: test-only-password' 'test-token' 'win11-64-24h2-hw-alpha' ''
Test-DeployMode 'nuc13-018' '' 'test-token' 'win11-64-24h2-hw' `
    "Deployment secrets 'win11-64-24h2-hw-alpha-02-06-2026.yaml' are missing or invalid. Restore the file with win_adminpw before redeploying."
Test-DeployMode 't-nuc12-002' 'unrelated_key: test-only-value' 'test-token' 'win11-64-24h2-hw-ref' `
    "Deployment secrets 'win11-64-24h2-hw-ref-alpha-02-24-2026.yaml' are missing or invalid. Restore the file with win_adminpw before redeploying."
Test-DeployMode 't-nuc12-002' 'win_adminpw: test-only-password' '' 'win11-64-24h2-hw-ref' `
    'The deployment share is missing a usable pat.txt. Restore it before redeploying.'

$sysprep = Read-Ast (Join-Path $root 'provisioners/windows/win-hw-wim/scripts/sysprep-generalize.ps1')
$assignment = $sysprep.Find({ param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -eq '$runner'
}, $true)
$runner = $assignment.Right.Expression.Value
if (-not $runner) { throw 'Generated startup script not found.' }
# Keep exit from terminating the test process.
$runner = [scriptblock]::Create($runner.Replace('exit 1', "throw 'retry next boot'"))

function Get-ItemProperty {
    param($Path, $ErrorAction)
    if ($Path -eq 'HKLM:\SYSTEM\Setup') { return [pscustomobject]@{ SystemSetupInProgress = $script:setupInProgress } }
    [pscustomobject]@{ bootstrap_stage = $script:stage }
}
function Get-CimInstance {
    if ($script:commandLine) { [pscustomobject]@{ CommandLine = $script:commandLine } }
}
function Test-Path {
    param($Path, $LiteralPath, $PathType)
    if ($script:missingSecrets -and $LiteralPath -like 'D:\secrets\*') { return $false }
    if ($script:missingBootstrap -and $Path -eq 'C:\bootstrap\bootstrap.ps1') { return $false }
    return $script:filesAvailable
}
function Start-Sleep { }
function New-Item { }
function Copy-Item { if ($script:copyFails) { throw 'copy failed' } }
function powercfg { }
function Tee-Object {
    param([Parameter(ValueFromPipeline)]$InputObject, $FilePath, [switch]$Append)
    process { $script:messages += [string]$InputObject }
}
function Unregister-ScheduledTask { $script:removed++ }
function Start-Process {
    $script:launches++
    $script:stage = $script:childStage
    return [pscustomobject]@{ ExitCode = $script:childExit }
}
function Check-Runner($Name, $Stage, $CommandLine, $ChildExit, $ChildStage, $Files, $CopyFails, $Launches, $Removed, $Fails) {
    $script:stage = $Stage; $script:commandLine = $CommandLine
    $script:childExit = $ChildExit; $script:childStage = $ChildStage
    $script:missingBootstrap = $false; $script:filesAvailable = $Files; $script:copyFails = $CopyFails
    $script:launches = 0; $script:removed = 0; $script:messages = @()
    $failed = $false
    try { & $runner } catch { $failed = $true }
    if ($script:launches -ne $Launches -or $script:removed -ne $Removed -or $failed -ne $Fails) {
        throw "$Name failed: launches=$script:launches removed=$script:removed failed=$failed"
    }
}
Check-Runner 'completed boot' complete '' 0 complete $true $false 0 1 $false
Check-Runner 'running bootstrap' inprogress 'powershell -File C:\bootstrap\bootstrap.ps1' 0 complete $true $false 0 0 $false
Check-Runner 'running first-logon launcher' setup 'powershell -File "D:\scripts\Get-Bootstrap.ps1"' 0 complete $true $false 0 0 $false
Check-Runner 'unrelated process' setup 'powershell -File C:\other\bootstrap.ps1' 0 complete $true $false 1 1 $false
Check-Runner 'failed launch' setup '' 5 setup $true $false 1 0 $true
Check-Runner 'incomplete child' setup '' 0 inprogress $true $false 1 0 $true
Check-Runner 'missing deployment drive' setup '' 0 setup $false $false 0 0 $true
Check-Runner 'failed prerequisite' setup '' 0 setup $true $true 0 0 $true
Check-Runner 'retry succeeds' inprogress '' 0 complete $true $false 1 1 $false

$getBootstrap = Read-Ast (Join-Path $root 'provisioners/windows/MDC1Windows/Get-Bootstrap.ps1')
$launch = $getBootstrap.FindAll({ param($node) $node -is [System.Management.Automation.Language.StatementAst] }, $true) | Where-Object {
    $_.Extent.Text.StartsWith('$bootstrapProcess =') -or
    $_.Extent.Text.StartsWith('if ($bootstrapProcess.ExitCode')
}
if ($launch.Count -ne 2) { throw 'PsExec launch check not found.' }
$launchScript = [scriptblock]::Create(($launch.Extent.Text -join "`n"))
function Start-Process {
    param($FilePath, [switch]$Wait, [switch]$PassThru, [switch]$NoNewWindow, $ArgumentList)
    $script:launches++
    if (-not $Wait -or -not $PassThru -or $ArgumentList -contains '-d') { throw 'PsExec must wait for bootstrap.' }
    if ($FilePath -ne 'D:\applications\psexec.exe' -or $ArgumentList -notcontains '-s' -or $ArgumentList -notcontains '-i') {
        throw 'PsExec launch context changed.'
    }
    if ($script:startFails) { throw 'PsExec could not start' }
    return [pscustomobject]@{ ExitCode = $script:processExit }
}
$local_bootstrap = 'C:\bootstrap\bootstrap.ps1'
$worker_images_revision = 'a' * 40
foreach ($case in @(
    @{ code = 0; startFails = $false; fails = $false },
    @{ code = 5; startFails = $false; fails = $true },
    @{ code = 0; startFails = $true; fails = $true }
)) {
    $script:processExit = $case.code; $script:startFails = $case.startFails
    $failed = $false
    try { & $launchScript } catch { $failed = $true }
    if ($failed -ne $case.fails) { throw 'PsExec exit propagation failed.' }
}

$flow = $getBootstrap.EndBlock.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.TryStatementAst]
}
if ($flow.Count -ne 1) { throw 'Bootstrap execution flow not found.' }
$flowScript = [scriptblock]::Create($flow.Extent.Text)
function Test-ConnectionUntilOnline { $script:prerequisites++; if ($script:prerequisiteFails) { throw 'network failed' } }
function Set-SSH { $script:sshCalls++; if ($script:sshFails) { throw 'SSH failed' } }
function Get-LocalUser { [pscustomobject]@{ SID = [pscustomobject]@{ Value = 'S-1-5-21-1-2-3-500' } } }
function Set-LocalUser { param([Parameter(ValueFromPipeline)] $InputObject, $Password) process { $script:adminPasswordSet++ } }
function Enable-LocalUser { param([Parameter(ValueFromPipeline)] $InputObject) process { $script:adminEnabled++ } }
function powercfg.exe { }
function Get-ScheduledTask { param($TaskName, $ErrorAction) return $TaskName }
function Unregister-ScheduledTask { param($InputObject, [switch]$Confirm) $script:removed++ }
function Invoke-DownloadWithRetryGithub { }
function Get-Content { return 'test credential' }
function New-ItemProperty { }
function Write-Log {
    param($message, $severity)
    $script:events += ,@{ message = $message; severity = $severity }
    if ($severity -eq 'ERROR' -and $script:errorLogFails) { throw 'event log failed' }
}
foreach ($case in @(
    @{ name = 'other launcher'; lock = $false; stage = 'setup'; command = ''; fails = $false; calls = 0 },
    @{ name = 'completed'; lock = $true; stage = 'complete'; command = ''; fails = $false; calls = 0 },
    @{ name = 'orphaned child'; lock = $true; stage = 'inprogress'; command = 'powershell -File C:\bootstrap\bootstrap.ps1'; fails = $false; calls = 0 },
    @{ name = 'failed prerequisite'; prerequisiteFails = $true; lock = $true; stage = 'setup'; command = ''; fails = $true; calls = 1 },
    @{ name = 'failed error logging'; prerequisiteFails = $true; logFails = $true; lock = $true; stage = 'setup'; command = ''; fails = $true; calls = 1 },
    @{ name = 'missing download'; missingBootstrap = $true; lock = $true; stage = 'setup'; command = ''; fails = $true; calls = 1; ssh = 1 },
    @{ name = 'missing secrets on boot'; missingSecrets = $true; lock = $true; stage = 'setup'; command = ''; fails = $true; calls = 1; ssh = 1 },
    @{ name = 'normal launch'; lock = $true; stage = 'setup'; command = ''; fails = $false; calls = 1; ssh = 1; launches = 1 },
    @{ name = 'missing pool secrets recovery'; recovery = 'Restore deployment secrets'; lock = $true; stage = 'setup'; fails = $false; calls = 0; ssh = 1; removed = 2 },
    @{ name = 'known-bad recovery after reboot'; recovery = 'Repair the Known-BAD node'; lock = $true; stage = 'complete'; fails = $false; calls = 0; ssh = 1; removed = 2 },
    @{ name = 'failed recovery SSH retries'; recovery = 'Fix reverse DNS'; lock = $true; sshFails = $true; fails = $true; calls = 0; ssh = 1 },
    @{ name = 'recovery waits for setup'; recovery = 'Fix reverse DNS'; lock = $true; setupInProgress = $true; fails = $true; calls = 0 }
)) {
    $bootstrapSkipReason = $case.recovery
    $script:missingSecrets = $case.missingSecrets; $script:sshFails = $case.sshFails
    $script:setupInProgress = $case.setupInProgress
    $script:sshCalls = 0; $script:removed = 0; $script:launches = 0
    $script:adminPasswordSet = 0; $script:adminEnabled = 0
    $script:lockAvailable = $case.lock; $script:stage = $case.stage; $script:commandLine = $case.command
    $script:prerequisiteFails = $case.prerequisiteFails; $script:missingBootstrap = $case.missingBootstrap; $script:prerequisites = 0
    $script:released = 0; $script:disposed = 0; $script:filesAvailable = $true
    $script:events = @(); $script:errorLogFails = $case.logFails
    $script:startFails = $false; $script:processExit = 0; $ownsMutex = $false
    $bootstrapMutex = [pscustomobject]@{}
    $bootstrapMutex | Add-Member ScriptMethod WaitOne { param($Timeout) return $script:lockAvailable }
    $bootstrapMutex | Add-Member ScriptMethod ReleaseMutex { $script:released++ }
    $bootstrapMutex | Add-Member ScriptMethod Dispose { $script:disposed++ }
    $failed = $false
    try { & $flowScript } catch { $failed = $true; $failure = $_ }
    if ($failed -ne $case.fails -or $script:prerequisites -ne $case.calls -or
        $script:released -ne [int]$case.lock -or $script:disposed -ne 1 -or
        $script:launches -ne [int]$case.launches -or $script:sshCalls -ne [int]$case.ssh -or
        $script:removed -ne [int]$case.removed) {
        throw "Launcher guard failed: $($case.name): $failure"
    }
    if ($case.recovery -and $case.ssh -and ($script:adminPasswordSet -ne 1 -or $script:adminEnabled -ne 1 -or
        -not ($script:events | Where-Object { $_.message -like "*$($case.recovery)*" }))) {
        throw "Recovery SSH setup or remediation log missing: $($case.name)."
    }
    if ($case.missingBootstrap -and $failure.Exception.Message -notmatch 'Downloaded bootstrap.ps1 is missing') { throw 'Missing download did not retain the retry path.' }
    if ($case.logFails -and $failure.Exception.Message -ne 'network failed') { throw 'Logging hid the original failure.' }
    if (($script:events.message -join ' ') -match 'test credential') { throw 'Credential appeared in logs.' }
    if (-not $script:events.Count) { throw "Missing lifecycle log: $($case.name)" }
    if ($case.fails -and -not ($script:events | Where-Object severity -eq 'ERROR')) { throw 'Bootstrap failure was not logged.' }
}
$global:LASTEXITCODE = 0
Write-Host 'WIM bootstrap handoff checks passed.'
