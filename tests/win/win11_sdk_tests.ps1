Param(
    [String]
    $File
)

BeforeDiscovery {
    $Hiera = Get-HieraRoleData -Path $File
}

Describe "Microsoft Tools" {
    It "<_.DisplayName> is installed" -ForEach @(
        Show-Win11SDK
    ) {
        $PSItem.DisplayName -in $Names | Should -Not -Be $null
    }
    It "<_.DisplayName> is 10.1.22621.1778" -ForEach @(
        Show-Win11SDK
    ) {
        $PSItem.DisplayVersion | Should -Be "10.1.22621.1778"
    }
}
