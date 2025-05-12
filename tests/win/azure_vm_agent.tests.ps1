Param(
    [String]
    $File
)

BeforeDiscovery {
    $Hiera = Get-HieraRoleData -Path $File
}

Describe "Windows Azure VM Agent" {
    BeforeAll {
        $Software = Get-InstalledSoftware | Where-Object {
            $PSItem.DisplayName -like "Windows Azure VM Agent*"
        }
        $ExpectedSoftwareVersion = [Version]($Hiera.'win-worker'.azure.vm_agent.version -split "_")[0]
    }
    It "Windows Azure VM Agent is installed" {
        $Software.DisplayName | Should -Not -Be $Null
    }
    It "Windows Azure VM Agent major version" {
        ([Version]$Software.DisplayVersion).Major | Should -Be $ExpectedSoftwareVersion.Major
    }
    It "Windows Azure VM Agent minor version" {
        ([Version]$Software.DisplayVersion).Minor | Should -Be $ExpectedSoftwareVersion.Minor
    }
    It "Windows Azure VM Agent build version" {
        ([Version]$Software.DisplayVersion).Build | Should -Be $ExpectedSoftwareVersion.Build
    }
    It "Windows Azure VM Agent revision" {
        ([Version]$Software.DisplayVersion).Revision | Should -Be $ExpectedSoftwareVersion.Revision
    }
}
