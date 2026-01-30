
function Disable-AntiVirus {
    [CmdletBinding()]
    param (

    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Log -message ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    Write-Host "========== $($MyInvocation.MyCommand.Name) started at $((Get-Date).ToUniversalTime().ToString('o')) =========="

    $avPreference = @(
        @{DisableArchiveScanning = $true }
        @{DisableAutoExclusions = $true }
        @{DisableBehaviorMonitoring = $true }
        @{DisableBlockAtFirstSeen = $true }
        @{DisableCatchupFullScan = $true }
        @{DisableCatchupQuickScan = $true }
        @{DisableIntrusionPreventionSystem = $true }
        @{DisableIOAVProtection = $true }
        @{DisablePrivacyMode = $true }
        @{DisableScanningNetworkFiles = $true }
        @{DisableScriptScanning = $true }
        @{MAPSReporting = 0 }
        @{PUAProtection = 0 }
        @{SignatureDisableUpdateOnStartupWithoutEngine = $true }
        @{SubmitSamplesConsent = 2 }
        @{ScanAvgCPULoadFactor = 5; ExclusionPath = @("D:\", "C:\", "Y:\", "Z:\") }
        @{DisableRealtimeMonitoring = $true }
    )

    $avPreference += @(
        @{EnableControlledFolderAccess = "Disable" }
        @{EnableNetworkProtection = "Disabled" }
    )

    $avPreference | Foreach-Object {
        $avParams = $_
        Set-MpPreference @avParams
    }

    Get-ScheduledTask -TaskPath '\Microsoft\Windows\Windows Defender\' | Disable-ScheduledTask | Out-Null

    $atpRegPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection'
    if (Test-Path $atpRegPath) {
        Set-ItemProperty -Path $atpRegPath -Name 'ForceDefenderPassiveMode' -Value '1' -Type 'DWORD'
    }

    $stopwatch.Stop()
    Write-Log -message ('{0} :: completed in {1} minutes, {2} seconds' -f $($MyInvocation.MyCommand.Name), $stopwatch.Elapsed.Minutes, $stopwatch.Elapsed.Seconds) -severity 'DEBUG'
    Write-Host "========== $($MyInvocation.MyCommand.Name) completed in $($stopwatch.Elapsed.Minutes) minutes, $($stopwatch.Elapsed.Seconds) seconds =========="
}