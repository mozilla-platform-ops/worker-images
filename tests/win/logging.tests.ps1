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
                "50F79F98DAC192B20DBF73F35C56F0B0C557AB267FF5199D1117CC1180B70785" # LF
                "188AE83F98B8ADB53B0FF3380CE9F8725B945923ACAB8AA22F66363485390FF7" # CRLF
            )
            $validHashes | Should -Contain (Get-FileHash -LiteralPath $bundle -Algorithm SHA256).Hash
        }
    }
}
