Describe "Cache VCS Checkout" {
    It "Mozilla Unified Directory" {
        Test-Path "C:\hg-shared" | Should -Be True
    }
    It "Mozilla Unified contains revision" {
        (Get-ChildItem "C:\hg-shared\*").Name -match '\d' | Should -Be True
    }
}
