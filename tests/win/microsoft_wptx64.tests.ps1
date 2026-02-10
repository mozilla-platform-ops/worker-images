Describe "WPTx64" {
    BeforeAll {
        $osFacts = Get-WinFactsCustomOS
        $osVersion = Get-OSVersionExtended
        $displayVersion = $osVersion.DisplayVersion

        # Determine expected package name and version based on architecture and OS
        if ($osFacts.arch -eq "aarch64") {
            # ARM64 uses plain WPTx64 regardless of OS version
            $expectedPackageName = "WPTx64"
            $expectedVersion = "10.1.16299.15"
        }
        elseif ($displayVersion -eq "24H2") {
            # Win11 24H2 x64 uses WPTx64 (DesktopEditions)
            $expectedPackageName = "WPTx64 (DesktopEditions)"
            $expectedVersion = "10.1.22621.5040"
        }
        elseif ($displayVersion -eq "2009" -or $osVersion.CurrentBuild -eq "19041") {
            # Win10/11 2009 uses plain WPTx64
            $expectedPackageName = "WPTx64"
            $expectedVersion = "10.1.19041.685"
        }
        else {
            # Win2022 and trusted images use older WPTx64
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
        $software.DisplayVersion | Should -Be $expectedVersion
    }
}
