Describe "Cache VCS Checkout" {
    BeforeAll {
        $CacheName = "gecko-level-1-checkouts-sparse"
        $CachePath = "C:\worker-runner\caches\$CacheName"
        $MetadataPath = "C:\worker-runner\directory-caches.json"
    }

    It "Mozilla Unified directory cache exists" {
        Test-Path $CachePath | Should -Be $true
    }

    It "Mozilla Unified shared store exists" {
        Test-Path (Join-Path $CachePath "hg-store") | Should -Be $true
    }

    It "Mozilla Unified sparse checkout exists" {
        Test-Path (Join-Path $CachePath "src\.hg") | Should -Be $true
    }

    It "Generic Worker directory cache metadata exists" {
        Test-Path $MetadataPath | Should -Be $true
    }

    It "Generic Worker can find the Mozilla Unified directory cache" {
        $metadata = Get-Content $MetadataPath -Raw | ConvertFrom-Json
        $cacheEntries = @($metadata.PSObject.Properties[$CacheName].Value)

        $cacheEntries | Should -Not -BeNullOrEmpty
        $cacheEntries[0].location | Should -Be $CachePath
        $cacheEntries[0].key | Should -Be $CacheName
        $cacheEntries[0].in_use | Should -Be $false
        Test-Path $cacheEntries[0].location | Should -Be $true
    }
}
