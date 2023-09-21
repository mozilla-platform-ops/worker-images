Param(
    [Parameter()]
    [String]
    $File
)

BeforeDiscovery {
    $Hiera = Get-HieraRoleData -Path $File
}

Describe "Git" {
    BeforeAll {
        $Git = Get-InstalledSoftware | Where-Object {
            $PSItem.DisplayName -match "Git"
        }
        $ExpectedSoftwareVersion = [Version]($Hiera["win-worker"].git.version)
    }
    It "Git is installed" {
        $Git.DisplayName | Should -Not -Be $null
    }

    It "Git Version is $ExpectedSoftwareVersion" {
        $Git.DisplayVersion | Should -Be $ExpectedSoftwareVersion
    }
}
