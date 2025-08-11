Describe "Cache VCS Checkout" {
    It "Mozilla Unified Directory" {
        Test-Path "C:\mozilla-unified" | Should -Be True
    }
    It "Mozilla Unified Contents" {
        Test-Path "C:\mozilla-unified\taskcluster" | Should -Be True
    }
}
