Describe "WPTx64" {
    BeforeAll {
        $software = Get-InstalledSoftware | Where-Object {
            $PSItem.DisplayName -eq "WPTx64"
        }
    }
    It "WPTx64 installed" {
        $software | Should -Not -Be $null
    }
    It "WPTx64 version" {
        $software.Version | Should -Be "10.1.16299.15"
    }
}
