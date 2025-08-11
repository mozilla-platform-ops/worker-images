Describe "Cache VCS Checkout" {
    It "Mozilla Unified Directory" {
        Test-Path "C:\mozilla-unified" | Should -Be True
    }
    It "Mozilla Unified Contents" {
        Test-Path "C:\mozilla-unified\.hg" | Should -Be True
    }
    It "Mozilla Unified Cache Folder Environment Variable" {
        $ENV:VCS_CHECKOUT | Should -Be "C:\mozilla-unified"
    }
}
