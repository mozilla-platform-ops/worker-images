## CLEAN-UP Can this be removed?

Param(
    [String]
    $File
)

BeforeDiscovery {
    $Hiera = Get-HieraRoleData -Path $File
}

Describe "Nvidia GPU Downloaded" {
    BeforeAll {
        $gpu = ($Hiera.'win-worker'.gpu.name)
    }
    It "Nvidia GPU Drivers are downloaded" {
        Test-Path "C:\$gpu" | Should -Be $true
    }
}
