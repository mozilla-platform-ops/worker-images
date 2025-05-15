Describe "Common Tools" {
    BeforeDiscovery {
        $Hiera = $Data.Hiera
    }

    BeforeAll {
        $7zip = Get-InstalledSoftware | Where-Object {
            $PSItem.DisplayName -match "Zip"
        }
    }
    Context "7-Zip" {
        It "7-Zip is installed" {
            $7zip.DisplayName | Should -Not -Be $null
        }

        It "7-Zip Version is 18.06.00.0" {
            $7zip.DisplayVersion | Should -Be "18.06.00.0"
        }
    }
}
