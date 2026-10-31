# Runs as SYSTEM during Windows Setup, independently of Ronin.
[CmdletBinding()]
param([switch] $ForWindowsSetup)
$ErrorActionPreference = 'Stop'
$transcribing = $false
try {
    Start-Transcript -Path "$env:SystemRoot\Temp\remove-build-access.log" -Append | Out-Null
    $transcribing = $true
    $task = Get-ScheduledTask -ErrorAction Stop | Where-Object TaskName -eq 'BakeNetwork'
    if ($task) {
        Stop-ScheduledTask -InputObject $task
        Unregister-ScheduledTask -InputObject $task -Confirm:$false
    }
    $policy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WinRM\Service'
    if (Test-Path -LiteralPath $policy) {
        foreach ($name in 'AllowBasic', 'AllowUnencryptedTraffic') {
            if ((Get-ItemProperty -LiteralPath $policy).PSObject.Properties[$name]) {
                Remove-ItemProperty -LiteralPath $policy -Name $name
            }
        }
    }
    $tokenPolicy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    if ((Test-Path -LiteralPath $tokenPolicy) -and
        (Get-ItemProperty -LiteralPath $tokenPolicy).PSObject.Properties['LocalAccountTokenFilterPolicy']) {
        Remove-ItemProperty -LiteralPath $tokenPolicy -Name LocalAccountTokenFilterPolicy
    }
    $service = Get-Service -ErrorAction Stop | Where-Object Name -eq 'WinRM'
    if ($service) {
        # WSMan needs its service running to remove persisted listener settings.
        Set-Service -Name WinRM -StartupType Manual
        Start-Service -Name WinRM
        Set-Item WSMan:\localhost\Service\Auth\Basic -Value $false
        Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $false
        Get-ChildItem WSMan:\localhost\Listener | Remove-Item -Recurse -Force
        if (@(Get-ChildItem WSMan:\localhost\Listener).Count) { throw 'WinRM listeners remain.' }
        Stop-Service -Name WinRM -Force
        Set-Service -Name WinRM -StartupType Disabled
        $state = Get-CimInstance Win32_Service -Filter "Name='WinRM'"
        if ($state.State -ne 'Stopped' -or $state.StartMode -ne 'Disabled') { throw 'WinRM is not stopped and disabled.' }
    }
    Get-NetFirewallRule | Where-Object DisplayName -eq 'WinRM-HTTP-In-5985' | Remove-NetFirewallRule
    if (@(Get-NetFirewallRule | Where-Object DisplayName -eq 'WinRM-HTTP-In-5985').Count) { throw 'Build firewall rule remains.' }
    $account = Get-LocalUser -ErrorAction Stop | Where-Object Name -eq 'packer'
    if ($account) {
        Disable-LocalUser -InputObject $account
        if ((Get-LocalUser -Name packer).Enabled) { throw 'Build account remains enabled.' }
    }
    $networkHelper = "$env:SystemRoot\Setup\Scripts\set-bake-network.ps1"
    if (Test-Path -LiteralPath $networkHelper) { Remove-Item -LiteralPath $networkHelper -Force }
    Write-Host 'Build access cleanup complete.'
}
catch {
    if ($ForWindowsSetup) {
        Write-Warning ("Build access cleanup failed: {0}" -f $_)
        exit 3
    }
    throw
}
finally { if ($transcribing) { Stop-Transcript -ErrorAction Continue | Out-Null } }
