## CLEAN-UP Software versions should be in Hiera

## Skip if this is run on a builder
Describe "Microsoft Tools - Tester" {
    BeforeDiscovery {
        $Hiera = $Data.Hiera
    }

    BeforeAll {
        $Directories = Get-WinFactsDirectories
        $VCC2022 = @(Show-VCC2022)
    }
    It "<_.DisplayName> is installed" -ForEach @(
        Show-Win10SDK
    ) {
        $PSItem.DisplayName -in $Names | Should -Not -Be $null
    }
    It "<_.DisplayName> is 10.1.19041.685" -ForEach @(
        Show-Win10SDK
    ) {
        $PSItem.DisplayVersion | Should -Be "10.1.19041.685"
    }
    It "<_.DisplayName> is installed" -ForEach @(
        Show-WinDotNet48
    ) {
        $_.DisplayName | Should -Not -Be $Null
    }
    It "<_.DisplayName> is version 4.8.04084" -ForEach @(
        Show-WinDotNet48
    ) {
        $_.DisplayVersion | Should -Be "4.8.04084"
    }
    It "Microsoft Visual C++ 2015-2022 packages are installed" {
        $VCC2022.Count | Should -Be 6
    }
    It "Microsoft Visual C++ 2015-2022 packages are version 14.40.33810" {
        $VCC2022 | Where-Object {
            $_.DisplayVersion -notlike "14.40.33810*"
        } | Should -BeNullOrEmpty
    }
    It "<_.DisplayName> is installed" -ForEach @(
        Show-Win10SDKAddon
    ) {
        $_.DisplayName |  Should -Not -Be $Null
    }
    It "<_.DisplayName> is version 10.1.0.0" -ForEach @(
        Show-Win10SDKAddon
    ) {
        $_.DisplayVersion | Should -Be 10.1.0.0
    }
}
