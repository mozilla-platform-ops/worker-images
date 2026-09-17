# Selected only by the 25H2 alpha cache test image.
Describe "Preloaded cache smoke seed" {
    It "Contains the expected marker and creation stamp" {
        (Get-Content 'C:\cache-seeds\relops-8809-smoke-20260917\marker.txt' -Raw).Trim() | Should -BeExactly 'from-image-78da8f580'
        (Get-Content 'C:\cache-seeds\relops-8809-smoke-20260917.created' -Raw).Trim() | Should -BeExactly '78da8f5807fb6f033039394ad9c196ed81bc8de2'
    }
    It "Configures generic-worker to import the marker" {
        $config = Get-Content 'C:\worker-runner\runner.yml' -Raw | ConvertFrom-Yaml
        $config.workerConfig.preloadedDirectoryCaches.Count | Should -Be 2
        $seed = $config.workerConfig.preloadedDirectoryCaches[0]
        $seed.cacheName | Should -BeExactly 'relops-8809-smoke-20260917'
        $seed.location | Should -BeExactly 'C:\cache-seeds\relops-8809-smoke-20260917'
    }
    It "Restricts seed access to SYSTEM and Administrators" {
        $acl = Get-Acl 'C:\cache-seeds'
        $acl.AreAccessRulesProtected | Should -BeTrue
        foreach ($rule in $acl.Access) {
            $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
            $sid | Should -BeIn @('S-1-5-18', 'S-1-5-32-544')
        }
    }
}

Describe "Preloaded Gecko checkout" {
    It "Contains a full checkout at the recorded revision" {
        $seed = 'C:\cache-seeds\gecko'
        $receipt = Get-Content "$seed\seed-receipt.json" -Raw | ConvertFrom-Json
        $node = & 'C:\Program Files\Mercurial\hg.exe' -R "$seed\src" log -r . -T '{node}'
        $LASTEXITCODE | Should -Be 0
        $node | Should -BeExactly $receipt.revision
        Test-Path "$seed\src\.hg\sparse" | Should -BeFalse
        Test-Path "$seed\src\mach" | Should -BeTrue
        Test-Path "$seed\src\toolkit\components" | Should -BeTrue
        $store = (Get-Content "$seed\src\.hg\sharedpath" -Raw).Trim()
        Test-Path $store | Should -BeTrue
        $store | Should -BeLike 'C:\hg-shared\*'
    }
    It "Imports the checkout into the try cache" {
        $config = Get-Content 'C:\worker-runner\runner.yml' -Raw | ConvertFrom-Yaml
        $seed = @($config.workerConfig.preloadedDirectoryCaches | Where-Object cacheName -eq 'gecko-level-1-checkouts')
        $seed.Count | Should -Be 1
        $seed[0].location | Should -BeExactly 'C:\cache-seeds\gecko'
    }
}
