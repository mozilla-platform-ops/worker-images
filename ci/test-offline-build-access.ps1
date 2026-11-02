$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$payload = Join-Path $root 'provisioners/windows/win-hw-wim/scripts/post-install/Remove-BuildAccess.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($payload, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$function = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Remove-OfflineBuildAccess'
}, $true)
if (-not $function) { throw 'Offline cleanup function not found.' }
. ([scriptblock]::Create($function.Extent.Text))
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function reg.exe {
    param($Action, $Key, $File)
    $global:offlineTest.calls += "$Action $Key"
    $global:LASTEXITCODE = if (($global:offlineTest.case -eq 'load' -and $Action -eq 'load' -and $Key.EndsWith('SYSTEM')) -or
        ($global:offlineTest.case -eq 'unload' -and $Action -eq 'unload' -and $Key.EndsWith('SYSTEM'))) { 5 } else { 0 }
}
function Test-Path {
    param($LiteralPath)
    if ($LiteralPath.EndsWith('Listener')) { return $global:offlineTest.listeners }
    return $global:offlineTest.case -ne 'missing' -and $LiteralPath.StartsWith('Registry::')
}
function Get-ChildItem {
    if ($global:offlineTest.case -ne 'controlsets') {
        'ControlSet001', 'ControlSet002', 'Select' | ForEach-Object { [pscustomobject]@{ PSChildName = $_ } }
    }
}
function Get-ItemProperty {
    param($LiteralPath, $Name)
    if ($LiteralPath -match '(ControlSet[0-9]{3})') {
        $controlSet = $Matches[1]
        if ($LiteralPath.EndsWith('WinRM')) { return [pscustomobject]@{ Start = $global:offlineTest.starts[$controlSet] } }
        if ($LiteralPath.EndsWith('FirewallRules')) { return [pscustomobject]$global:offlineTest.rules[$controlSet] }
    }
    [pscustomobject]$global:offlineTest.policy
}
function Set-ItemProperty {
    param($LiteralPath, $Name, $Value)
    if ($global:offlineTest.case -ne 'service') {
        Assert ($LiteralPath -match '(ControlSet[0-9]{3})') 'Writing outside an offline control set.'
        $global:offlineTest.starts[$Matches[1]] = $Value
    }
}
function Remove-ItemProperty {
    param($LiteralPath, $Name)
    if ($global:offlineTest.case -eq 'policy') { throw 'policy denied' }
    if ($LiteralPath -match '(ControlSet[0-9]{3})') {
        if ($global:offlineTest.case -ne 'firewall') { $global:offlineTest.rules[$Matches[1]].Remove($Name) }
    }
    else { $global:offlineTest.policy.Remove($Name) }
}
function Remove-Item {
    param($LiteralPath)
    Assert ($LiteralPath.EndsWith('Listener')) 'Removing an unexpected offline path.'
    if ($global:offlineTest.case -ne 'listener') { $global:offlineTest.listeners = $false }
}
try {
    foreach ($case in 'success', 'missing', 'load', 'policy', 'listener', 'service', 'controlsets', 'unload', 'firewall') {
        $global:offlineTest = @{
            case = $case; calls = @(); listeners = ($case -ne 'missing')
            policy = @{ AllowBasic = 1; AllowUnencryptedTraffic = 1; LocalAccountTokenFilterPolicy = 1; Unrelated = 7 }
            starts = @{ ControlSet001 = 2; ControlSet002 = 3 }
            rules = @{
                ControlSet001 = @{ Build = 'v2|Name=WinRM-HTTP-In-5985|'; SSH = 'v2|Name=OpenSSH|'; Similar = 'v2|Name=WinRM-HTTP-In-5985-other|' }
                ControlSet002 = @{ Build = 'v2|Name=WinRM-HTTP-In-5985|'; SSH = 'v2|Name=OpenSSH|' }
            }
        }
        $failure = $null
        try { Remove-OfflineBuildAccess -WindowsRoot 'test-windows' } catch { $failure = $_ }
        $expected = switch ($case) {
            'load' { 'Cannot load offline SYSTEM' }
            'policy' { 'policy denied' }
            'listener' { 'listeners remain' }
            'service' { 'service is not disabled' }
            'controlsets' { 'No offline control sets' }
            'unload' { 'Cannot unload offline hive' }
            'firewall' { 'firewall rules remain' }
            default { '' }
        }
        if ($expected) { Assert ($failure -and $failure.ToString().Contains($expected)) "Expected $expected; got $failure" }
        else { Assert (-not $failure) "Unexpected failure: $failure" }
        $unloads = @($global:offlineTest.calls | Where-Object { $_ -like 'unload *' })
        Assert ($unloads.Count -eq $(if ($case -eq 'load') { 1 } else { 2 })) "Loaded hives leaked: $case"
        Assert ($unloads[-1].EndsWith('SOFTWARE')) 'Hive cleanup order changed.'
        if ($case -eq 'success') {
            foreach ($controlSet in 'ControlSet001', 'ControlSet002') {
                Assert ($global:offlineTest.starts[$controlSet] -eq 4) 'A control set retained enabled WinRM.'
                Assert (-not $global:offlineTest.rules[$controlSet].ContainsKey('Build')) 'Build firewall rule remains.'
                Assert ($global:offlineTest.rules[$controlSet].ContainsKey('SSH')) 'SSH firewall access was removed.'
            }
            Assert ($global:offlineTest.rules.ControlSet001.ContainsKey('Similar')) 'A similarly named unrelated rule was removed.'
            Assert ($global:offlineTest.policy.Count -eq 1 -and $global:offlineTest.policy.Unrelated -eq 7) 'Unrelated policy was changed.'
            Remove-OfflineBuildAccess -WindowsRoot 'test-windows'
        }
    }
}
finally { Remove-Variable offlineTest -Scope Global; $global:LASTEXITCODE = 0 }
# A failed child process must stop the real WinPE deployment block before reboot.
$deploy = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'provisioners/windows/MDC1Windows/OS-deploy.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$check = $deploy.Find({ param($node)
    $node -is [Management.Automation.Language.IfStatementAst] -and
    $node.Extent.Text.StartsWith('if ($LASTEXITCODE -ne 0) { throw "Offline build access cleanup failed:')
}, $true)
Assert ([bool]$check) 'WinPE cleanup result check is missing.'
foreach ($code in 0, 1, 3) {
    $global:LASTEXITCODE = $code
    $failure = $null
    try { & ([scriptblock]::Create($check.Extent.Text)) } catch { $failure = $_ }
    Assert ([bool]$failure -eq ($code -ne 0)) 'WinPE continued after cleanup failure.'
}
$global:LASTEXITCODE = 0
Write-Host 'Offline build access checks passed.'
