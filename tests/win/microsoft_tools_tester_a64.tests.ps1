Param(
    [String]
    $File
)

BeforeDiscovery {
    $Hiera = Get-HieraRoleData -Path $File
}

## Skip if this is run on a builder
Describe "Microsoft Tools - Tester" {
    BeforeAll {
        $Directories = Get-WinFactsDirectories
        $software = Get-InstalledSoftware | Where-Object {
            $PSItem.DisplayName -eq "WPTx64"
        }
    }
    It "WPTx64 is installed" {
        $software | Should -Not -Be $null
    }
}