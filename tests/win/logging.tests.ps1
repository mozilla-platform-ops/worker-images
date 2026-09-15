## CLEAN-UP Version should be moved into Hiera
Describe "Logging" {
    BeforeDiscovery {
        $Hiera = $Data.Hiera
    }

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
    Context "Papertrail CA bundle is current" {
        It "Uses the bundle managed by Puppet" {
            $bundle = "${env:ProgramFiles(x86)}\nxlog\cert\papertrail-bundle.pem"
            $validHashes = @(
                "AE31ECB3C6E9FF3154CB7A55F017090448F88482F0E94AC927C0C67A1F33B9CF" # LF
                "DAB0D52F01E2AFC16A80ABBCADEF312CD09680639BCEB6B1BBC43BA9C7FCAEAF" # CRLF
            )
            $validHashes | Should -Contain (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
        }
    }
}
