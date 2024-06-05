Param(
    [String]
    $File
)

BeforeDiscovery {
    $Hiera = Get-HieraRoleData -Path $File
}

Describe "Nvidia GPU Downloaded" {
    BeforeAll {
        $gpu = ($Hiera.'win-worker'.'gpu-latest'.name)
    }
    It "Nvidia GPU Drivers are downloaded" {
        Test-Path "C:\538.15_grid_win10_win11_server2019_server2022_dch_64bit_international_azure_swl.exe" | Should -Be $true
    }
}
