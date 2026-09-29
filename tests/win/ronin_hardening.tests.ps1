# Opt in only for images pinned to Ronin's privileged-path hardening.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Hiera', Justification = 'Pester consumes Hiera in BeforeDiscovery.')]
param([hashtable]$Hiera)

Describe "Ronin privileged-path permissions" {
    BeforeDiscovery {
        $win = $Hiera.windows
        $variant = $Hiera.'win-worker'.variant
        $nssm = if ($variant.nssm.version) { $variant.nssm.version } else { $win.nssm.version }
        if (-not $nssm) { throw 'NSSM version is missing from Hiera' }
        $ronin = "$env:ProgramData\PuppetLabs\ronin"
        $paths = @(
            foreach ($path in @(
                "$env:SystemDrive\RoninPackages",
                "$env:SystemDrive\nssm",
                "$env:SystemDrive\nssm\nssm-$nssm",
                "$env:SystemDrive\nssm\nssm-$nssm\win64",
                "$env:SystemDrive\generic-worker",
                $ronin, "$ronin\ronin", "$ronin\semaphore"
            )) {
                @{ Path = $path; AllowUsers = $true; Protected = $true }
            }
            foreach ($name in @('generic-worker.exe', 'taskcluster-proxy.exe', 'livelog.exe', 'task-user-init.cmd', 'task-user-init.ps1')) {
                @{ Path = "$env:SystemDrive\generic-worker\$name"; AllowUsers = $true; Protected = $false }
            }
            @{ Path = "$env:SystemDrive\nssm\nssm-$nssm\win64\nssm.exe"; AllowUsers = $true; Protected = $true }
            @{ Path = "$env:SystemDrive\worker-runner"; AllowUsers = $false; Protected = $true }
            foreach ($name in @('start-worker.exe', 'runner.yml')) {
                @{ Path = "$env:SystemDrive\worker-runner\$name"; AllowUsers = $false; Protected = $false }
            }
            # Fail discovery if staging is missing; do not silently test an empty list.
            $packages = @(Get-ChildItem -LiteralPath "$env:SystemDrive\RoninPackages" -File -ErrorAction Stop)
            if ($packages.Count -eq 0) { throw 'RoninPackages contains no staged files' }
            foreach ($package in $packages) {
                @{ Path = $package.FullName; AllowUsers = $true; Protected = $true }
            }
        )
    }

    It "Protects <Path>" -ForEach $paths {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        if ($Protected) {
            $acl.AreAccessRulesProtected | Should -BeTrue
            $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value | Should -Be 'S-1-5-18'
        }
        $expected = @{
            'S-1-5-18' = [System.Security.AccessControl.FileSystemRights]::FullControl
            'S-1-5-32-544' = [System.Security.AccessControl.FileSystemRights]::FullControl
        }
        if ($AllowUsers) {
            $expected['S-1-5-32-545'] = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [System.Security.AccessControl.FileSystemRights]::Synchronize
        }
        $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        $rules.Count | Should -Be $expected.Count
        @($rules.IdentityReference.Value | Sort-Object -Unique).Count | Should -Be $expected.Count
        foreach ($rule in $rules) {
            $sid = $rule.IdentityReference.Value
            $expected.ContainsKey($sid) | Should -BeTrue
            $rule.AccessControlType | Should -Be 'Allow'
            $rule.FileSystemRights | Should -Be $expected[$sid]
            $rule.PropagationFlags | Should -Be 'None'
            if ($item.PSIsContainer) {
                $rule.InheritanceFlags | Should -Be 'ContainerInherit, ObjectInherit'
            }
        }
    }
}
