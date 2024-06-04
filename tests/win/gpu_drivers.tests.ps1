Param(
    [String]
    $File
)

BeforeDiscovery {
    $Hiera = Get-HieraRoleData -Path $File
}

Describe "Nvidia GPU Downloaded" {
    BeforeAll {
        $gpu = ($Hiera.'win-worker'.gpu.name) + ".zip"
    }
    It "Nvidia GPU Drivers are downloaded" {
        Test-Path "C:\472.39_grid_win11_win10_64bit_Azure-SWL" | Should -Be $true
    }
}
