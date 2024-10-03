function Set-OOBE {
    param (
    )

    Write-Log -message ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'

    ## Get the current os
    $OS = Get-OSVersionExtended

    switch ($os.DisplayVersion) {
        "24H2" {
            Write-Log -message ('{0} :: Setting additional OOBE Reg Entries for {1} - {2:o}' -f $($MyInvocation.MyCommand.Name), $os.DisplayVersion, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
            ## This is for 24H2 in Azure since OOBE still asks for location in gui
            @(
                "HideEULAPage",
                "HideLocalAccountScreen",
                "HideOEMRegistrationScreen",
                "HideOnlineAccountScreens",
                "HideWirelessSetupInOOBE",
                "NetworkLocation",
                "OEMAppId",
                "ProtectYourPC",
                "SkipMachineOOBE",
                "SkipUserOOBE"
            ) | ForEach-Object {
                Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" -Name $psitem -Value 1
            }
        }
        Default {
            Write-Log -message ('{0} :: Skipping additional OOBE Reg Entries for {1} - {2:o}' -f $($MyInvocation.MyCommand.Name), $os.DisplayVersion, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
            Continue
        }
    }

}
