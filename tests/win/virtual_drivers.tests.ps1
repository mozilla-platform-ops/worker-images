Param(
    [String]
    $File
)

BeforeDiscovery {
    $Hiera = Get-HieraRoleData -Path $File
}

Describe "Virtual Audio Cable" {
    BeforeAll {
        $Software = Get-InstalledSoftware | Where-Object {
            $PSItem.DisplayName -like "Virtual Audio Cable*"
        }
    }
    It "Virtual Audio Cable is installed" {
        $Software.DisplayName | Should -Not -Be $Null
    }
    It "Virtual Audio Cable is version 4.64" {
        $Software.DisplayVersion | Should -Be "4.64"
    }
}
