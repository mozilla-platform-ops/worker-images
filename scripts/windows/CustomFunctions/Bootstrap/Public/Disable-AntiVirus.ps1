
function Disable-AntiVirus {
    [CmdletBinding()]
    param (
        
    )
    
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
}