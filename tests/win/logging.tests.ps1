Param(
    [String]
    $File
)

BeforeDiscovery {
    $Hiera = Get-HieraRoleData -Path $File
}

Describe "Logging" {
    BeforeAll {
        $Software = Get-InstalledSoftware | Where-Object {
            $PSItem.DisplayName -like "NXLog-CE*"
        }
    }
    Context "NXLog is installed" {
        It "NXLog is installed" {
            $Software.DisplayName | Should -Not -Be $Null
        }
        It "NXLog is version 2.10.2150" {
            $Software.DisplayVersion | Should -Be "2.10.2150"
        }
    }
}
