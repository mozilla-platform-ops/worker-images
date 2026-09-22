Describe "File System Management" {
    BeforeDiscovery {
        $Hiera = $Data.Hiera
    }

    It "Disable 8.3 Formatted Name" {
        Get-ItemPropertyValue "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "NtfsDisable8dot3NameCreation" | Should -Be 1
    }
    It "Disable Last Acccess" {
        Get-ItemPropertyValue "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "NtfsDisableLastAccessUpdate" | Should -Be 2147483649
    }
    It "Long paths enabled" -Skip {
        Get-ItemPropertyValue "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "LongPathsEnabled" | Should -Be 1
    }
}
