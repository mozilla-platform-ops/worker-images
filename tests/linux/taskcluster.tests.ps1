Describe "Taskcluster" {
    Context "Generic Worker" {
        It "Generic Worker exists" {
            Test-Path "/usr/local/bin/generic-worker" | Should -Be $true
        }
        It "Generic Worker Version is current" {
            $null = generic-worker --short-version > gw.txt
            Get-Content gw.txt | Should -be $ENV:TASKCLUSTER_VERSION
        }
    }
}