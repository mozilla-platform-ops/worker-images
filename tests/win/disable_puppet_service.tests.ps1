Describe "Puppet Windows Service" {
    Context "puppet service" {
        It "Puppet service exists" {
            Get-Service $_ | Should -Not -Be $null
        }
        It "Puppet service exists is disabled" {
            (Get-Service $_).Status | Should -Be "Stopped"
        }
    }
}
