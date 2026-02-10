Describe "WPTx64" {
    BeforeAll {
        $osVersion = Get-OSVersionExtended
        $displayVersion = $osVersion.DisplayVersion
        $osArch = (Get-CimInstance Win32_OperatingSystem).OSArchitecture
        $osCaption = (Get-CimInstance Win32_OperatingSystem).Caption

        # Determine expected package name and version based on OS
        if ($displayVersion -eq "24H2") {
            # Win11 24H2 uses WPTx64 (DesktopEditions) or (OnecoreUAP)
            $expectedPackageName = "WPTx64 (DesktopEditions)"
            $expectedVersion = "10.1.22621.5040"
        }
        elseif ($displayVersion -eq "2009" -or $osVersion.CurrentBuild -eq "19041") {
            # Win10/11 2009 uses plain WPTx64
            $expectedPackageName = "WPTx64"
            $expectedVersion = "10.1.19041.685"
        }
        else {
            # ARM64, Win2022, and trusted images use older WPTx64
            $expectedPackageName = "WPTx64"
            $expectedVersion = "10.1.16299.15"
        }

        $software = Get-InstalledSoftware | Where-Object {
            $PSItem.DisplayName -eq $expectedPackageName
        }
    }

    It "WPTx64 installed" {
        $software | Should -Not -Be $null
    }

    It "WPTx64 version" {
        $software.Version | Should -Be $expectedVersion
    }
}
