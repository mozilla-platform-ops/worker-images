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
        Test-Path "C:\$gpu" | Should -Be $true
    }
}
