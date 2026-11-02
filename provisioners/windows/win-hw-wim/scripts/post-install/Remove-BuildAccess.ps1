# Runs during Windows Setup or against the applied OS from WinPE.
[CmdletBinding()]
param(
    [switch] $ForWindowsSetup,
    [string] $OfflineWindowsRoot
)

function Remove-OfflineBuildAccess {
    param([Parameter(Mandatory)] [string] $WindowsRoot)
    $prefix = 'BuildAccess' + [guid]::NewGuid().ToString('N')
    $loaded = @()
    try {
        foreach ($hive in 'SOFTWARE', 'SYSTEM') {
            $name = "$prefix$hive"
            & reg.exe load "HKLM\$name" (Join-Path $WindowsRoot "System32\config\$hive") | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Cannot load offline $hive hive." }
            $loaded += $name
        }
        $software = "Registry::HKEY_LOCAL_MACHINE\${prefix}SOFTWARE"
        $system = "Registry::HKEY_LOCAL_MACHINE\${prefix}SYSTEM"
        foreach ($entry in @(
            @{ path = "$software\Policies\Microsoft\Windows\WinRM\Service"; names = @('AllowBasic', 'AllowUnencryptedTraffic') },
            @{ path = "$software\Microsoft\Windows\CurrentVersion\Policies\System"; names = @('LocalAccountTokenFilterPolicy') }
        )) {
            if (Test-Path -LiteralPath $entry.path) {
                foreach ($name in $entry.names) {
                    if ((Get-ItemProperty -LiteralPath $entry.path).PSObject.Properties[$name]) {
                        Remove-ItemProperty -LiteralPath $entry.path -Name $name
                    }
                }
            }
        }
        $listeners = "$software\Microsoft\Windows\CurrentVersion\WSMAN\Listener"
        if (Test-Path -LiteralPath $listeners) { Remove-Item -LiteralPath $listeners -Recurse -Force }
        if (Test-Path -LiteralPath $listeners) { throw 'Offline WinRM listeners remain.' }
        $controlSets = @(Get-ChildItem -LiteralPath $system | Select-Object -ExpandProperty PSChildName | Where-Object { $_ -match '^ControlSet[0-9]{3}$' })
        if (-not $controlSets.Count) { throw 'No offline control sets found.' }
        foreach ($controlSet in $controlSets) {
            $service = "$system\$controlSet\Services\WinRM"
            if (Test-Path -LiteralPath $service) {
                Set-ItemProperty -LiteralPath $service -Name Start -Value 4 -Type DWord
                if ((Get-ItemProperty -LiteralPath $service -Name Start).Start -ne 4) { throw 'Offline WinRM service is not disabled.' }
            }
            $rules = "$system\$controlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules"
            if (Test-Path -LiteralPath $rules) {
                foreach ($property in (Get-ItemProperty -LiteralPath $rules).PSObject.Properties) {
                    if ($property.Value -is [string] -and $property.Value -match '(?:^|\|)Name=WinRM-HTTP-In-5985(?:\||$)') {
                        Remove-ItemProperty -LiteralPath $rules -Name $property.Name
                    }
                }
                $remaining = @((Get-ItemProperty -LiteralPath $rules).PSObject.Properties | Where-Object {
                    $_.Value -is [string] -and $_.Value -match '(?:^|\|)Name=WinRM-HTTP-In-5985(?:\||$)'
                })
                if ($remaining.Count) { throw 'Offline build firewall rules remain.' }
            }
        }
        $helper = Join-Path $WindowsRoot 'Setup\Scripts\set-bake-network.ps1'
        if (Test-Path -LiteralPath $helper) { Remove-Item -LiteralPath $helper -Force }
    }
    finally {
        [array]::Reverse($loaded)
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        $failures = @()
        foreach ($name in $loaded) {
            & reg.exe unload "HKLM\$name" | Out-Null
            if ($LASTEXITCODE -ne 0) { $failures += "Cannot unload offline hive $name." }
        }
        if ($failures.Count) { throw ($failures -join ' ') }
    }
}
$ErrorActionPreference = 'Stop'
$transcribing = $false
$logRoot = $env:SystemRoot
if ($OfflineWindowsRoot) {
    $OfflineWindowsRoot = (Resolve-Path -LiteralPath $OfflineWindowsRoot).ProviderPath
    if ($OfflineWindowsRoot.TrimEnd('\') -ieq "$env:SystemRoot".TrimEnd('\')) { throw 'Offline target cannot be the running Windows installation.' }
    $logRoot = $OfflineWindowsRoot
}
try {
    New-Item -ItemType Directory -Path (Join-Path $logRoot 'Temp') -Force | Out-Null
    Start-Transcript -Path (Join-Path $logRoot 'Temp\remove-build-access.log') -Append | Out-Null
    $transcribing = $true
    if ($OfflineWindowsRoot) {
        Remove-OfflineBuildAccess -WindowsRoot $OfflineWindowsRoot
        Write-Host 'Offline build access cleanup complete.'
        return
    }
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
