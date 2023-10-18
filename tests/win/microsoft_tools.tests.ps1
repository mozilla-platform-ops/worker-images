Param(
    [String]
    $File
)

BeforeDiscovery {
    $Hiera = Get-HieraRoleData -Path $File
    $Directories = Get-WinFactsDirectories
}

## Skip if this is run on a builder
Describe "Microsoft Tools - Tester" -Skip:@(Assert-IsBuilder) {
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
    It "<_.DisplayName> is installed" -ForEach @(
        Show-vcc2019
    ) {
        $_.DisplayName | Should -Not -Be $Null
    }
    It "<_.DisplayName> is version 14.26.28720" -ForEach @(
        Show-vcc2019
    ) {
        $_.DisplayVersion | Should -Be "14.26.28720"
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

## Skip if this is run on a tester
Describe "Microsoft Tools - Builder" -Skip:@(Assert-IsTester) {
    BeforeAll {
        $software = Get-InstalledSoftware
        $directxsdk = $software | Where-Object {
            $PSItem.DisplayName -like "Directx*"
        }
        $binscope = $software | Where-Object {
            $PSItem.DisplayName -eq "Microsoft BinScope 2014"
        }
        $vccx86 = $software | Where-Object {
            $PSItem.DisplayName -eq "Microsoft Visual C++ 2015 Redistributable (x86) - 14.0.23918"
        }
        $vccx64 = $software | Where-Object {
            $PSItem.DisplayName -eq "Microsoft Visual C++ 2015 Redistributable (x64) - 14.0.23918"
        }
        $system_env = Get-ChildItem env:
    }
    It "NET Framework Core is installed" {
        Get-WindowsFeature -Name "NET-Framework-Core" | Should -Not -Be $Null
    }
    It "DirectX SDK gets installed" {
        $directxsdk.DisplayName | Should -Not -Be $Null
    }
    It "DirectX SDK version" {
        $directxsdk.DisplayVersion | Should -Be "9.29.1962.0"
    }
    It "DirectX Environment Variable is set" {
        $sdkenv | Where-Object {$PSItem.name -eq "DXSDK_DIR"} | Should -Not -Be $Null
    }
    It "DirectX Environment Variable is set to correct path" {
        $sdkpath = $system_env | Where-Object {$PSItem.name -eq "DXSDK_DIR"} 
        $sdkpath.value | Should -Be "$(Directories.custom_win_programfilesx86)\Microsoft DirectX SDK (June 2010)"
    }
    It "Microsoft BinScope 2014 gets installed" {
        $binscope.DisplayName | Should -Not -Be $Null
    }
    It "Microsoft BinScope 2014 version" {
        $binscope.DisplayVersion | Should -Be "7.0.7000.0"
    }
    It "Visual c++ runtime 2015 x86 gets installed" {
        $vccx86.DisplayName | Should -Not -Be $Null
    }
    It "Visual c++ runtime 2015 x86 version" {
        $vccx86.DisplayVersion | Should -Be "14.0.23918.0"
    }
    It "Visual c++ runtime 2015 x64 gets installed" {
        $vccx64.DisplayName | Should -Not -Be $Null
    }
    It "Visual c++ runtime 2015 x64 version" {
        $vccx64.DisplayVersion | Should -Be "14.0.23918.0"
    }
}