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
        Test-Path "$systemdrive\Windows\Temp\$($gpu).exe" | Should -Be $true
    }
}
