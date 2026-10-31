$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scripts = Join-Path $root 'provisioners/windows/win-hw-wim/scripts'
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
function Expect-Failure($Action, $Message) {
    $failure = $null
    try { & $Action } catch { $failure = $_ }
    Assert ($failure -and $failure.ToString().Contains($Message)) "Expected $Message; got $failure"
}
foreach ($file in @('post-install.ps1', 'post-install/Remove-BuildAccess.ps1', 'add-post-install-to-wim.ps1',
    'capture-wim.ps1', 'create-iso.ps1', '../bin/WinHwWim/New-WinHwWim.ps1', '../../MDC1Windows/OS-deploy.ps1')) {
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts $file), [ref]$tokens, [ref]$errors) | Out-Null
    Assert (-not $errors.Count) ($errors | Out-String)
}
. (Join-Path $scripts 'post-install.ps1')
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('post-install-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    # Cover bare WIM staging and ISO payload/answer-file staging.
    foreach ($media in $false, $true) {
        $windows = if ($media) { Join-Path $scratch 'iso/sources/$OEM$/$$' } else { Join-Path $scratch 'wim/Windows' }
        $answer = if ($media) { Join-Path $scratch 'iso/autounattend.xml' } else { Join-Path $windows 'Panther/unattend.xml' }
        $args = @{ WindowsRoot = $windows; UnattendPath = $answer }
        Install-PostInstallCleanup @args
        [xml]$xml = Get-Content -LiteralPath $answer -Raw
        $hook = $xml.SelectNodes("//*[local-name()='RunSynchronousCommand']/*[local-name()='Path' and contains(text(),'Remove-BuildAccess.ps1')]")
        Assert ($hook.Count -eq 1) 'Cleanup hook missing from generated answer file.'
        Assert ($hook[0].ParentNode.ParentNode.ParentNode.ParentNode.pass -eq 'specialize') 'Cleanup is not a specialize command.'
        Assert (Test-Path -LiteralPath (Join-Path $windows 'Setup/Scripts/Remove-BuildAccess.ps1')) 'Cleanup payload missing.'
        Install-PostInstallCleanup @args
        [xml]$xml = Get-Content -LiteralPath $answer -Raw
        Assert ($xml.SelectNodes("//*[local-name()='Path' and contains(text(),'Remove-BuildAccess.ps1')]").Count -eq 1) 'Staging duplicated the command.'
    }
    $answer = Join-Path $scratch 'existing.xml'
    Copy-Item (Join-Path $root 'provisioners/windows/MDC1Windows/base-autounattend.xml') $answer
    [xml]$before = Get-Content $answer -Raw
    $oldHook = $before.SelectSingleNode("//*[local-name()='RunSynchronousCommand']/*[local-name()='Path' and contains(text(),'Remove-BuildAccess.ps1')]").ParentNode
    $oldHook.ParentNode.RemoveChild($oldHook) | Out-Null
    $before.Save($answer)
    $beforeCount = $before.SelectNodes("//*[local-name()='Path']").Count
    Install-PostInstallCleanup -WindowsRoot (Join-Path $scratch 'existing/Windows') -UnattendPath $answer
    [xml]$after = Get-Content $answer -Raw
    Assert ($after.SelectNodes("//*[local-name()='Path']").Count -eq ($beforeCount + 1)) 'Existing deployment commands were changed or duplicated.'
    Assert ($after.SelectNodes("//*[local-name()='FirstLogonCommands']").Count -eq 1) 'Ronin first-logon configuration was removed.'
}
finally { Remove-Item -LiteralPath $scratch -Recurse -Force }

# Exercise multi-edition WIM servicing and discard the mount when staging fails.
function Get-WindowsImage { 1, 2 | ForEach-Object { [pscustomobject]@{ ImageIndex = $_ } } }
function Mount-WindowsImage {
    param($ImagePath, $Index, $Path)
    $global:imageTest.mount = $Path
    $global:imageTest.mounted++
    if ($global:imageTest.fail -and $Index -eq 2) {
        $panther = Join-Path $Path 'Windows/Panther'
        New-Item -ItemType Directory -Path $panther -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $panther 'unattend.xml') -Value 'invalid XML'
    }
}
function Dismount-WindowsImage {
    param($Path, [switch] $Save, [switch] $Discard)
    if ($Save) {
        Assert (Test-Path -LiteralPath (Join-Path $Path 'Windows/Setup/Scripts/Remove-BuildAccess.ps1')) 'WIM edition has no cleanup payload.'
        $global:imageTest.saved++
    }
    if ($Discard) { $global:imageTest.discarded++ }
    Get-ChildItem -LiteralPath $Path | Remove-Item -Recurse -Force
}
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('post-install-wim-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    foreach ($fail in $false, $true) {
        $global:imageTest = @{ fail = $fail; mounted = 0; saved = 0; discarded = 0; mount = '' }
        $wim = Join-Path $scratch 'test.wim'
        Set-Content -LiteralPath $wim -Value 'test-only WIM placeholder'
        Set-Content -LiteralPath "$wim.sha256" -Value 'old checksum'
        $failed = $false
        try { & (Join-Path $scripts 'add-post-install-to-wim.ps1') -Wim $wim } catch { $failed = $true }
        Assert ($failed -eq $fail) 'Unexpected WIM servicing result.'
        Assert ($global:imageTest.mounted -eq 2) 'Not all WIM editions were serviced.'
        Assert ($global:imageTest.saved -eq $(if ($fail) { 1 } else { 2 })) 'Wrong number of saved editions.'
        Assert ($global:imageTest.discarded -eq [int]$fail) 'Failed WIM mount was not discarded.'
        Assert (-not (Test-Path -LiteralPath $global:imageTest.mount)) 'WIM mount directory leaked.'
        Assert ((Test-Path -LiteralPath "$wim.sha256") -eq (-not $fail)) 'Checksum published after a servicing failure.'
    }
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
    Remove-Variable imageTest -Scope Global
    foreach ($mock in 'Get-WindowsImage', 'Mount-WindowsImage', 'Dismount-WindowsImage') { Remove-Item "Function:\$mock" }
}

# Run the actual cleanup with Windows APIs mocked; no real access settings change.
function Start-Transcript {}
function Stop-Transcript { $global:cleanupTest.closed++ }
function Get-ScheduledTask { if ($global:cleanupTest.task) { [pscustomobject]@{ TaskName = 'BakeNetwork' } } }
function Stop-ScheduledTask {}
function Unregister-ScheduledTask { $global:cleanupTest.task = $false }
function Test-Path { param($LiteralPath); return $LiteralPath -like 'HKLM:*' }
function Get-ItemProperty { return [pscustomobject]$global:cleanupTest.policy }
function Remove-ItemProperty {
    param($LiteralPath, $Name)
    if ($global:cleanupTest.case -eq 'policy') { throw 'policy denied' }
    $global:cleanupTest.policy.Remove($Name)
}
function Get-Service { if ($global:cleanupTest.case -ne 'absent') { [pscustomobject]@{ Name = 'WinRM' } } }
function Set-Service {}
function Start-Service {}
function Stop-Service {}
function Set-Item {}
function Get-ChildItem { if ($global:cleanupTest.listeners) { 'listener' } }
function Remove-Item {
    param([Parameter(ValueFromPipeline)] $InputObject, [switch] $Recurse, [switch] $Force)
    process { if ($global:cleanupTest.case -ne 'listener') { $global:cleanupTest.listeners = $false } }
}
function Get-CimInstance {
    [pscustomobject]@{ State = 'Stopped'; StartMode = $(if ($global:cleanupTest.case -eq 'service') { 'Auto' } else { 'Disabled' }) }
}
function Get-NetFirewallRule {
    if ($global:cleanupTest.firewall) { [pscustomobject]@{ DisplayName = 'WinRM-HTTP-In-5985' } }
}
function Remove-NetFirewallRule {
    param([Parameter(ValueFromPipeline)] $InputObject)
    process { if ($global:cleanupTest.case -ne 'firewall') { $global:cleanupTest.firewall = $false } }
}
function Get-LocalUser {
    if ($global:cleanupTest.case -ne 'absent') { [pscustomobject]@{ Name = 'packer'; Enabled = $global:cleanupTest.enabled } }
}
function Disable-LocalUser { if ($global:cleanupTest.case -ne 'account') { $global:cleanupTest.enabled = $false } }
try {
    foreach ($case in 'success', 'absent', 'listener', 'service', 'firewall', 'account', 'policy') {
        $global:cleanupTest = @{ case = $case; listeners = $true; firewall = $true; enabled = $true; closed = 0; task = $true; policy = @{ AllowBasic = 1; AllowUnencryptedTraffic = 1; LocalAccountTokenFilterPolicy = 1 } }
        $action = { & (Join-Path $scripts 'post-install/Remove-BuildAccess.ps1') }
        switch ($case) {
            'success' { & $action; & $action; Assert ($global:cleanupTest.policy.Count -eq 0 -and -not $global:cleanupTest.task) 'Temporary policy or network task remains.' }
            'absent' { & $action }
            'listener' { Expect-Failure $action 'listeners remain' }
            'service' { Expect-Failure $action 'not stopped and disabled' }
            'firewall' { Expect-Failure $action 'firewall rule remains' }
            'account' { Expect-Failure $action 'account remains enabled' }
            'policy' { Expect-Failure $action 'policy denied' }
        }
        Assert ($global:cleanupTest.closed -eq $(if ($case -eq 'success') { 2 } else { 1 })) 'Failure did not close the transcript.'
    }
    $global:cleanupTest = @{ case = 'service'; listeners = $false; firewall = $false; enabled = $false; closed = 0; task = $false; policy = @{} }
    & (Join-Path $scripts 'post-install/Remove-BuildAccess.ps1') -ForWindowsSetup
    Assert ($LASTEXITCODE -eq 3) 'Setup failure must return 3, not reboot request codes 1 or 2.'
    $global:LASTEXITCODE = 0
}
finally { Remove-Variable cleanupTest -Scope Global }
Write-Host 'Post-install cleanup checks passed.'
