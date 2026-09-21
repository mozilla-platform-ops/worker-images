# Selected only by the 25H2 alpha cache test image.
Describe "Preloaded cache smoke seed" {
    It "Contains the expected marker and creation stamp" {
        (Get-Content 'C:\cache-seeds\relops-8809-smoke-20260918\marker.txt' -Raw).Trim() | Should -BeExactly 'from-image-e29a4639f'
        (Get-Content 'C:\cache-seeds\relops-8809-smoke-20260918.created' -Raw).Trim() | Should -BeExactly 'e29a4639fd4402431b7a01cb9982b145c3077aa9'
    }
    It "Configures generic-worker to register the marker" {
        $config = Get-Content 'C:\worker-runner\runner.yml' -Raw | ConvertFrom-Yaml
        $config.workerConfig.preloadedDirectoryCaches.Count | Should -Be 3
        $seed = $config.workerConfig.preloadedDirectoryCaches[0]
        $seed.cacheName | Should -BeExactly 'relops-8809-smoke-20260918'
        $seed.location | Should -BeExactly 'C:\cache-seeds\relops-8809-smoke-20260918'
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
        ($store -replace '/', '\') | Should -BeLike 'C:\hg-shared\*'
        (Get-Content "$seed\src\.hg\preloaded-cache-proof" -Raw).Trim() | Should -BeExactly $receipt.revision
    }
    It "Registers the checkout as the try cache" {
        $config = Get-Content 'C:\worker-runner\runner.yml' -Raw | ConvertFrom-Yaml
        $seed = @($config.workerConfig.preloadedDirectoryCaches | Where-Object cacheName -eq 'gecko-level-1-checkouts')
        $seed.Count | Should -Be 1
        $seed[0].location | Should -BeExactly 'C:\cache-seeds\gecko'
    }
}

Describe "Preloaded pip cache" {
    It "Contains a prepared package cache and proof" {
        $seed = 'C:\cache-seeds\pip'
        $proof = Get-Content "$seed\preloaded-cache-proof.json" -Raw | ConvertFrom-Json
        $proof.package | Should -BeExactly 'six==1.17.0'
        $proof.worker_revision | Should -BeExactly 'e29a4639fd4402431b7a01cb9982b145c3077aa9'
        @(Get-ChildItem $seed -Recurse -File | Where-Object Name -ne 'preloaded-cache-proof.json').Count | Should -BeGreaterThan 0
        Test-Path "$seed.created" | Should -BeTrue
    }
    It "Registers the pip cache under the task cache name" {
        $config = Get-Content 'C:\worker-runner\runner.yml' -Raw | ConvertFrom-Yaml
        $seed = @($config.workerConfig.preloadedDirectoryCaches | Where-Object cacheName -eq 'gecko-level-1-pip')
        $seed.Count | Should -Be 1
        $seed[0].location | Should -BeExactly 'C:\cache-seeds\pip'
    }
}
