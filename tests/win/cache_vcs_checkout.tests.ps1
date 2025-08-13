Describe "Cache VCS Checkout" {
    It "Mozilla Unified Directory" {
        Test-Path "C:\hg-shared" | Should -Be True
    }
    It "Mozilla Unified Contents" {
        Test-Path "C:\hg-shared\.hg" | Should -Be True
    }
}
