$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Read-Ast($Path) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    return $ast
}
$sysprep = Read-Ast (Join-Path $root 'provisioners/windows/win-hw-wim/scripts/sysprep-generalize.ps1')
$assignment = $sysprep.Find({ param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -eq '$runner'
}, $true)
$runner = $assignment.Right.Expression.Value
if (-not $runner) { throw 'Generated startup script not found.' }
# Keep exit from terminating the test process.
$runner = [scriptblock]::Create($runner.Replace('exit 1', "throw 'retry next boot'"))

function Get-ItemProperty { [pscustomobject]@{ bootstrap_stage = $script:stage } }
function Get-CimInstance {
    if ($script:commandLine) { [pscustomobject]@{ CommandLine = $script:commandLine } }
}
function Test-Path { param($Path) return $script:filesAvailable }
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
    $script:filesAvailable = $Files; $script:copyFails = $CopyFails
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
function Set-SSH { }
function Install-Choco { }
function Invoke-DownloadWithRetryGithub { }
function Get-Content { return 'test credential' }
function New-ItemProperty { }
foreach ($case in @(
    @{ name = 'other launcher'; lock = $false; stage = 'setup'; command = ''; fails = $false; calls = 0 },
    @{ name = 'completed'; lock = $true; stage = 'complete'; command = ''; fails = $false; calls = 0 },
    @{ name = 'orphaned child'; lock = $true; stage = 'inprogress'; command = 'powershell -File C:\bootstrap\bootstrap.ps1'; fails = $false; calls = 0 },
    @{ name = 'failed prerequisite'; lock = $true; stage = 'setup'; command = ''; fails = $true; calls = 1 },
    @{ name = 'normal launch'; lock = $true; stage = 'setup'; command = ''; fails = $false; calls = 1 }
)) {
    $script:lockAvailable = $case.lock; $script:stage = $case.stage; $script:commandLine = $case.command
    $script:prerequisiteFails = $case.fails; $script:prerequisites = 0
    $script:released = 0; $script:disposed = 0; $script:filesAvailable = $true
    $script:startFails = $false; $script:processExit = 0; $ownsMutex = $false
    $bootstrapMutex = [pscustomobject]@{}
    $bootstrapMutex | Add-Member ScriptMethod WaitOne { param($Timeout) return $script:lockAvailable }
    $bootstrapMutex | Add-Member ScriptMethod ReleaseMutex { $script:released++ }
    $bootstrapMutex | Add-Member ScriptMethod Dispose { $script:disposed++ }
    $failed = $false
    try { & $flowScript } catch { $failed = $true; $failure = $_ }
    if ($failed -ne $case.fails -or $script:prerequisites -ne $case.calls -or
        $script:released -ne [int]$case.lock -or $script:disposed -ne 1) {
        throw "Launcher guard failed: $($case.name): $failure"
    }
}
$global:LASTEXITCODE = 0
Write-Host 'WIM bootstrap handoff checks passed.'
