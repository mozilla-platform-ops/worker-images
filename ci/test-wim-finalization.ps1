$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scripts = Join-Path $root 'provisioners/windows/win-hw-wim/scripts'
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Expect-Failure($Action, $Message) {
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_ }
    Assert ($failure -and $failure.ToString().Contains($Message)) "Expected failure: $Message; got: $failure"
}
function Read-Ast($Path) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    Assert (-not $errors.Count) ($errors | Out-String)
    return $ast
}
foreach ($file in 'finalize-wim.ps1', 'assert-capture-ready.ps1', 'sysprep-generalize.ps1', 'capture-wim.ps1', 'unattend/set-bake-network.ps1') {
    Read-Ast (Join-Path $scripts $file) | Out-Null
}

# Preserve compatibility with the shipped client without enabling Basic or broad access.
$network = Read-Ast (Join-Path $scripts 'unattend/set-bake-network.ps1')
$transport = [scriptblock]::Create(($network.EndBlock.Statements | Where-Object {
    ($_.Extent.Text -like '$gw *=*') -or ($_.Extent.Text -like '$winrmPol =*') -or
    ($_.Extent.Text -like 'New-Item -Path $winrmPol*') -or
    ($_.Extent.Text -like 'Set-ItemProperty -Path $winrmPol*') -or
    ($_.Extent.Text -like 'Get-NetFirewallRule -ErrorAction Stop*') -or
    ($_.Extent.Text -like 'New-NetFirewallRule -DisplayName*')
}).Extent.Text -join "`n")
$global:wimTest = @{ policy = @{}; removed = 0; created = 0 }
function New-Item {}
function Set-ItemProperty {
    param($Path, $Name, $Value)
    $global:wimTest.policy[$Name] = $Value
}
function Get-NetFirewallRule { [pscustomobject]@{ DisplayName = 'WinRM-HTTP-In-5985' } }
function Remove-NetFirewallRule {
    param([Parameter(ValueFromPipeline)] $InputObject)
    process { $global:wimTest.removed++ }
}
function New-NetFirewallRule {
    param($DisplayName, $Direction, $Action, $Protocol, $LocalPort, $RemoteAddress)
    Assert ($global:wimTest.removed -eq 1) 'Existing broad build rule was not removed.'
    Assert ($RemoteAddress -eq '192.168.234.1' -and $LocalPort -eq 5985) 'Build WinRM access is not restricted to the NAT host.'
    $global:wimTest.created++
}
& $transport
Assert ($global:wimTest.policy.AllowBasic -eq 0) 'Build Basic authentication must remain disabled.'
Assert ($global:wimTest.policy.AllowUnencryptedTraffic -eq 1) 'Shipped client requires unencrypted HTTP during the bake.'
Assert ($global:wimTest.created -eq 1) 'Build firewall rule was not created.'
foreach ($mock in 'New-Item', 'Set-ItemProperty', 'Get-NetFirewallRule', 'Remove-NetFirewallRule', 'New-NetFirewallRule') {
    Microsoft.PowerShell.Management\Remove-Item "Function:\$mock"
}

# Exercise the host helper without Hyper-V or guest access.
function Get-VM {
    $global:wimTest.vmCalls++
    [pscustomobject]@{ State = $(if ($global:wimTest.case -eq 'stopped' -or
        ($global:wimTest.vmCalls -gt 1 -and $global:wimTest.case -ne 'timeout')) { 'Off' } else { 'Running' }) }
}
function New-PSSession {
    param($VMName, $Credential)
    Assert ($Credential.UserName -eq 'custom-builder') 'Finalizer ignored the configured username.'
    if ($global:wimTest.case -eq 'connect') { throw 'session failed' }
    'mock-session'
}
function Invoke-Command {
    param($Session, $FilePath, $ArgumentList)
    $global:wimTest.invocations++
    Assert ($ArgumentList -eq $true) 'Guest finalizer did not receive the PowerShell Direct flag.'
    if ($global:wimTest.case -eq 'guest') { throw 'guest failed' }
    if ($global:wimTest.case -ne 'marker') { 'WIM_FINALIZE_OK' }
}
function Remove-PSSession { $global:wimTest.closed++ }
function Get-Date { $global:wimTest.time = $global:wimTest.time.AddSeconds(2); $global:wimTest.time }
function Start-Sleep {}
$savedPassword = $env:PKR_VAR_winrm_password
try {
    foreach ($case in 'success', 'stopped', 'connect', 'guest', 'marker', 'timeout', 'password') {
        $global:wimTest = @{ case = $case; vmCalls = 0; invocations = 0; closed = 0; time = [datetime]'2026-01-01' }
        $env:PKR_VAR_winrm_password = if ($case -eq 'password') { '' } else { 'test-only-password' }
        $action = { & (Join-Path $scripts 'finalize-wim.ps1') -VmName 'test-vm' -Username 'custom-builder' -ShutdownTimeoutSec 1 }
        switch ($case) {
            'success' { & $action | Out-Null }
            'stopped' { Expect-Failure $action 'not running' }
            'connect' { Expect-Failure $action 'session failed' }
            'guest' { Expect-Failure $action 'guest failed' }
            'marker' { Expect-Failure $action 'did not confirm success' }
            'timeout' { Expect-Failure $action 'Timed out' }
            'password' { Expect-Failure $action 'PKR_VAR_winrm_password is required' }
        }
        $expectedClosed = if ($case -in 'stopped', 'connect', 'password') { 0 } else { 1 }
        Assert ($global:wimTest.closed -eq $expectedClosed) "Session cleanup failed: $case"
    }
}
finally { $env:PKR_VAR_winrm_password = $savedPassword }

# Verify removal failures stop finalization, including absent optional policy values.
$sysprepAst = Read-Ast (Join-Path $scripts 'sysprep-generalize.ps1')
$all = $sysprepAst.EndBlock.Statements
$entry = [scriptblock]::Create($sysprepAst.ParamBlock.Extent.Text + "`n" + ($all[0..2].Extent.Text -join "`n"))
Expect-Failure { & $entry } 'Finalization must run through'
& $entry $true
$begin = @($all | Where-Object { $_.Extent.Text -eq "Step 'Removing build-time WinRM access'" })[0].Extent.StartOffset
$end = @($all | Where-Object { $_.Extent.Text -eq "Step 'Disabling build-only packer account'" })[0].Extent.StartOffset
$cleanup = [scriptblock]::Create('Set-StrictMode -Version Latest' + "`n" + (($all | Where-Object {
    $_.Extent.StartOffset -ge $begin -and $_.Extent.StartOffset -lt $end
}).Extent.Text -join "`n"))
function Step {}
function Test-Path { return $global:wimTest.case -ne 'absent-policy' }
function Get-ItemProperty {
    param($LiteralPath)
    if ($global:wimTest.case -eq 'absent-policy') { return [pscustomobject]@{ PSPath = $LiteralPath } }
    [pscustomobject]@{ AllowBasic = 0; AllowUnencryptedTraffic = 0; LocalAccountTokenFilterPolicy = 1 }
}
function Remove-ItemProperty {}
function Set-Item {}
function Get-ChildItem { if ($global:wimTest.listeners) { 'listener' } }
function Remove-Item {
    param([Parameter(ValueFromPipeline)] $InputObject, [switch] $Recurse, [switch] $Force)
    process { if ($global:wimTest.case -ne 'listeners') { $global:wimTest.listeners = $false } }
}
function Get-NetFirewallRule {
    if ($global:wimTest.firewall) { [pscustomobject]@{ DisplayName = 'WinRM-HTTP-In-5985' } }
}
function Remove-NetFirewallRule {
    param([Parameter(ValueFromPipeline)] $InputObject)
    process { if ($global:wimTest.case -ne 'firewall') { $global:wimTest.firewall = $false } }
}
function Set-Service {}
function Stop-Service { if ($global:wimTest.case -eq 'stop') { throw 'stop denied' } }
function Get-CimInstance {
    [pscustomobject]@{ State = 'Stopped'; StartMode = $(if ($global:wimTest.case -eq 'service') { 'Auto' } else { 'Disabled' }) }
}
foreach ($case in 'success', 'absent-policy', 'listeners', 'firewall', 'stop', 'service') {
    $global:wimTest = @{ case = $case; listeners = $true; firewall = $true }
    switch ($case) {
        'success' { & $cleanup }
        'absent-policy' { & $cleanup }
        'listeners' { Expect-Failure $cleanup 'listeners remain' }
        'firewall' { Expect-Failure $cleanup 'firewall rule remains' }
        'stop' { Expect-Failure $cleanup 'stop denied' }
        'service' { Expect-Failure $cleanup 'not stopped and disabled' }
    }
}
foreach ($mock in 'Test-Path', 'Get-ItemProperty', 'Remove-ItemProperty', 'Set-Item', 'Get-ChildItem', 'Remove-Item',
    'Get-NetFirewallRule', 'Remove-NetFirewallRule', 'Set-Service', 'Stop-Service', 'Get-CimInstance') {
    Microsoft.PowerShell.Management\Remove-Item "Function:\$mock"
}

# Execute the guest's actual Sysprep/shutdown statements with native commands mocked.
$sysprep = Read-Ast (Join-Path $scripts 'sysprep-generalize.ps1')
$statements = $sysprep.EndBlock.Statements
$start = @($statements | Where-Object { $_.Extent.Text -eq "Step 'Running Sysprep /generalize /oobe /quit'" })[0].Extent.StartOffset
$finish = [scriptblock]::Create(($statements | Where-Object { $_.Extent.StartOffset -ge $start }).Extent.Text -join "`n")
function Step {}
function Start-Process {
    $process = [pscustomobject]@{ ExitCode = $(if ($global:wimTest.case -eq 'exit') { 5 } else { 0 }) }
    $process | Add-Member ScriptMethod WaitForExit { param($Timeout); return $global:wimTest.case -ne 'sysprep-timeout' }
    $process
}
function Get-ItemProperty {
    [pscustomobject]@{ ImageState = $(if ($global:wimTest.case -eq 'state') { 'IMAGE_STATE_UNDEPLOYABLE' } else { 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' }) }
}
function shutdown.exe {
    $global:wimTest.shutdown++
    $global:LASTEXITCODE = if ($global:wimTest.case -eq 'shutdown') { 5 } else { 0 }
}
$savedRoot = $env:SystemRoot
try {
    $env:SystemRoot = [IO.Path]::GetTempPath()
    foreach ($case in 'success', 'exit', 'sysprep-timeout', 'state', 'shutdown') {
        $global:wimTest = @{ case = $case; shutdown = 0 }
        switch ($case) {
            'success' { Assert ('WIM_FINALIZE_OK' -in @(& $finish)) 'Missing guest success marker.' }
            'exit' { Expect-Failure $finish 'Sysprep failed: 5' }
            'sysprep-timeout' { Expect-Failure $finish 'Sysprep timed out' }
            'state' { Expect-Failure $finish 'Unexpected Sysprep image state' }
            'shutdown' { Expect-Failure $finish 'Shutdown request failed' }
        }
        Assert ($global:wimTest.shutdown -eq $(if ($case -in 'success', 'shutdown') { 1 } else { 0 })) 'Shutdown requested after a Sysprep failure.'
    }
}
finally { $env:SystemRoot = $savedRoot }

# Inspect offline state and credentials using the real gate with mock registry hives.
. (Join-Path $scripts 'assert-capture-ready.ps1')
function reg.exe {
    param($Action, $Key, $File)
    $global:wimTest.calls += "$Action $Key"
    $global:LASTEXITCODE = if (($global:wimTest.case -eq 'load' -and $Action -eq 'load' -and $Key.EndsWith('SYSTEM')) -or
        ($global:wimTest.case -eq 'unload' -and $Action -eq 'unload' -and $Key.EndsWith('SYSTEM'))) { 5 } else { 0 }
}
function Get-ItemProperty {
    param($LiteralPath, $Name)
    switch ($Name) {
        'ImageState' { return [pscustomobject]@{ ImageState = $(if ($global:wimTest.case -eq 'state') { 'IMAGE_STATE_COMPLETE' } else { 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' }) } }
        'Current' { return [pscustomobject]@{ Current = $(if ($global:wimTest.case -eq 'controlset') { 0 } else { 1 }) } }
        'Start' { return [pscustomobject]@{ Start = $(if ($global:wimTest.case -eq 'service') { 2 } else { 4 }) } }
    }
    if ($LiteralPath.EndsWith('Winlogon') -and $global:wimTest.case -eq 'password') { return [pscustomobject]@{ DefaultPassword = 'test-only' } }
    if ($LiteralPath.EndsWith('Service') -and $global:wimTest.case -eq 'policy') { return [pscustomobject]@{ AllowBasic = 1 } }
    [pscustomobject]@{ PSPath = $LiteralPath }
}
function Test-Path {
    param($LiteralPath)
    if ($LiteralPath.StartsWith('Registry::')) { return $global:wimTest.case -in 'policy', 'empty-policy' }
    Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
}
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('wim-finalization-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    foreach ($case in 'success', 'empty-policy', 'state', 'controlset', 'service', 'password', 'policy', 'load', 'unload') {
        $global:wimTest = @{ case = $case; calls = @() }
        $action = { Assert-CaptureReady -Root $scratch }
        switch ($case) {
            'success' { & $action }
            'empty-policy' { & $action }
            'state' { Expect-Failure $action 'not generalized' }
            'controlset' { Expect-Failure $action 'no valid current control set' }
            'service' { Expect-Failure $action 'not disabled' }
            'password' { Expect-Failure $action 'autologon password remains' }
            'policy' { Expect-Failure $action 'policy remains enabled' }
            'load' { Expect-Failure $action 'Cannot load offline SYSTEM' }
            'unload' { Expect-Failure $action 'Cannot unload offline hive' }
        }
        $unloads = @($global:wimTest.calls | Where-Object { $_ -like 'unload *' })
        Assert ($unloads.Count -eq $(if ($case -eq 'load') { 1 } else { 2 })) "Offline hives not released: $case"
        Assert ($unloads[-1].EndsWith('SOFTWARE')) 'Offline hive cleanup order changed.'
    }
    foreach ($artifact in 'bake/secret.txt', 'wim-bake/password.txt', 'ronin/data/secrets/vault.yaml',
        'Windows/Setup/Scripts/set-bake-network.ps1', 'Windows/System32/Tasks/BakeNetwork',
        'Windows/Panther/UnattendGC/autounattend.xml', 'Windows/System32/Sysprep/unattend.xml') {
        $global:wimTest = @{ case = 'success'; calls = @() }
        $file = Join-Path $scratch $artifact
        New-Item -ItemType Directory -Path (Split-Path $file -Parent) -Force | Out-Null
        Set-Content -LiteralPath $file -Value 'test-only'
        $message = if ($artifact.EndsWith('unattend.xml')) { 'Cached answer files remain' } else { 'Build artifact remains' }
        Expect-Failure { Assert-CaptureReady -Root $scratch } $message
        Microsoft.PowerShell.Management\Remove-Item -LiteralPath $scratch -Recurse -Force
        New-Item -ItemType Directory -Path $scratch | Out-Null
    }
}
finally {
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $scratch -Recurse -Force
    Remove-Variable wimTest -Scope Global
    $global:LASTEXITCODE = 0
}
# The actual capture block must validate before DISM and dismount on every failure.
$captureAst = Read-Ast (Join-Path $scripts 'capture-wim.ps1')
$captureTry = $captureAst.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] }
Assert (@($captureTry).Count -eq 1) 'Capture block not found.'
$capture = [scriptblock]::Create($captureTry.Extent.Text)
function Get-Volume {
    $global:wimTest.volumes++
    [pscustomobject]@{ DriveLetter = 'C' }
    if ($global:wimTest.volumes -gt 1) { [pscustomobject]@{ DriveLetter = 'Z' } }
}
function Mount-VHD {}
function Dismount-VHD { $global:wimTest.dismounted++ }
function Test-Path { return $true }
function Assert-CaptureReady {
    $global:wimTest.checked++
    if ($global:wimTest.case -eq 'unsafe') { throw 'unsafe image' }
}
function New-WindowsImage {
    Assert ($global:wimTest.checked -eq 1) 'Capture ran before offline verification.'
    $global:wimTest.captured++
    if ($global:wimTest.case -eq 'dism') { throw 'DISM failed' }
}
$vhdx = [pscustomobject]@{ FullName = 'test.vhdx' }
$OutWim = 'test.wim'; $Name = 'test-image'
foreach ($case in 'success', 'unsafe', 'dism') {
    $global:wimTest = @{ case = $case; volumes = 0; checked = 0; captured = 0; dismounted = 0 }
    $mounted = $null
    switch ($case) {
        'success' { & $capture }
        'unsafe' { Expect-Failure $capture 'unsafe image' }
        'dism' { Expect-Failure $capture 'DISM failed' }
    }
    Assert ($global:wimTest.dismounted -eq 1) 'Capture did not dismount the VHDX.'
    Assert ($global:wimTest.captured -eq $(if ($case -eq 'unsafe') { 0 } else { 1 })) 'Unsafe image reached DISM.'
}
$metadata = [scriptblock]::Create(($captureAst.EndBlock.Statements | Where-Object {
    ($_.Extent.Text -like '$wimPath =*') -or ($_.Extent.Text -like '$images =*') -or
    ($_.Extent.Text.Contains("throw 'Captured WIM metadata"))
}).Extent.Text -join "`n")
function Get-WindowsImage {
    if ($global:wimTest.case -eq 'unreadable') { throw 'unreadable WIM' }
    if ($global:wimTest.case -eq 'empty') { return }
    [pscustomobject]@{ ImageName = $(if ($global:wimTest.case -eq 'wrong') { 'other-image' } else { 'test-image' }) }
    if ($global:wimTest.case -eq 'multiple') { [pscustomobject]@{ ImageName = 'test-image' } }
}
foreach ($case in 'success', 'unreadable', 'empty', 'wrong', 'multiple') {
    $global:wimTest = @{ case = $case }
    if ($case -eq 'success') { & $metadata }
    elseif ($case -eq 'unreadable') { Expect-Failure $metadata 'unreadable WIM' }
    else { Expect-Failure $metadata 'metadata does not match' }
}
Remove-Variable wimTest -Scope Global
Write-Host 'WIM finalization checks passed.'
