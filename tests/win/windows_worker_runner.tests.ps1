Param(
    [String]
    $File
)

BeforeDiscovery {
    $Hiera = Get-HieraRoleData -Path $File
}

Describe "Windows Worker Runner" {
    It "Custom NSSM exists" {
        Test-Path "C:\nssm\nssm-2.24\win64\nssm.exe" | Should -Be $true
    }
    It "Windows Service Exists" {
        Get-Service "worker-runner" | Should -Not -Be $null
    }
    It "Worker runner directory exists" {
        Test-Path "C:\worker-runner" | Should -Be $true
    }
}
