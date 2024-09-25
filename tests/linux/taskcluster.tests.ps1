
Describe "Taskcluster" {
    Context "Generic Worker" {
        It "Generic Worker exists" {
            Test-Path "/usr/local/bin/generic-worker" | Should -Be $true
        }
        It "Generic Worker Version is 70.0.0" {
            $null = generic-worker --short-version > gw.txt
            Get-Content gw.txt | Should -be "70.0.0"
        }
    }
}
