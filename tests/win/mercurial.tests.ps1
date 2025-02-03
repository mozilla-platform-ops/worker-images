Param(
    [String]
    $File
)

BeforeDiscovery {
    $Hiera = Get-HieraRoleData -Path $File
}

Describe "Mercurial" {
    BeforeAll {
        $Hg = Get-InstalledSoftware | Where-Object {
            $PSItem.DisplayName -match "Mercurial"
        }
        $ExpectedSoftwareVersion = [Version]($Hiera["win-worker"].hg.version)
    }
    It "Hg is installed" {
        $Hg.DisplayName | Should -Not -Be $null
    }

    It "Hg Version matches hiera" {
        $Hg.DisplayVersion | Should -Be $ExpectedSoftwareVersion
    }
}
