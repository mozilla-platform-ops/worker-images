Param(
    [String]
    $File
)

BeforeDiscovery {
    $Hiera = Get-HieraRoleData -Path $File
}

Describe "Taskcluster" {
    BeforeAll {
        $nssm = ($Hiera.'win-worker'.nssm.version)
    }
    Context "Non-Sucking Service Manager" {
        It "NSSM is installed" {
            Test-Path "C:\nssm\nssm-$($nssm)\win64\nssm.exe" | Should -Be $true
        }
        It "NSSM Windows Service Exists" {
            Get-Service "worker-runner" | Should -Not -Be $null
        }
        #It "Worker runner directory exists" {
        #    Test-Path "C:\worker-runner" | Should -Be $true
        #}
    }
}
