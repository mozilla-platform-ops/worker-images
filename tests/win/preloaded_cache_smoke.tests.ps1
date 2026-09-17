# Selected only by the 25H2 alpha cache test image.
Describe "Preloaded cache smoke seed" {
    It "Contains the expected marker and creation stamp" {
        (Get-Content 'C:\cache-seeds\relops-8809-smoke-20260917\marker.txt' -Raw).Trim() | Should -BeExactly 'from-image-78da8f580'
        (Get-Content 'C:\cache-seeds\relops-8809-smoke-20260917.created' -Raw).Trim() | Should -BeExactly '78da8f5807fb6f033039394ad9c196ed81bc8de2'
    }
    It "Configures generic-worker to import the marker" {
        $config = Get-Content 'C:\worker-runner\runner.yml' -Raw | ConvertFrom-Yaml
        $config.workerConfig.preloadedDirectoryCaches.Count | Should -Be 1
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
