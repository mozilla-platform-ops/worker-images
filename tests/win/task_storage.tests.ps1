Describe "Task storage configuration" {
    It "Configures direct task and cache paths" {
        $config = Get-Content 'C:\worker-runner\runner.yml' -Raw | ConvertFrom-Yaml
        $workVolume = (Get-ItemProperty 'HKLM:\SOFTWARE\Mozilla\ronin_puppet' -ErrorAction Stop).work_volume
        $tasksDir = if ($workVolume -eq 1) { 'D:\tasks' } else { 'C:\Users' }
        $drive = if ($workVolume -eq 1) { 'D:' } else { 'C:' }
        $config.workerConfig.tasksDir | Should -BeExactly $tasksDir
        if ($workVolume -eq 1) {
            'C:\ProgramData\PuppetLabs\ronin\configure_work_volume.ps1' | Should -Exist
        }
        $config.workerConfig.cachesDir | Should -BeExactly "$drive\caches"
        $config.workerConfig.downloadsDir | Should -BeExactly "$drive\downloads"
        Get-ItemPropertyValue 'HKLM:\SOFTWARE\Mozilla\ronin_puppet' -Name task_drive | Should -BeExactly 'C:'
    }

    It "Configures the pagefile on C:" {
        $paging = Get-ItemPropertyValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name PagingFiles
        @($paging) | Should -Contain 'C:\pagefile.sys 8192 8192'
        @($paging | Where-Object { $_ -like 'D:*' }).Count | Should -Be 0
    }
}

Describe 'Gecko image seed' -Skip:([string]::IsNullOrWhiteSpace($env:GECKO_HG_SEED_REVISION)) {
    BeforeAll {
        $hg = 'C:\Program Files\Mercurial\hg.exe'
        $git = 'C:\Program Files\Git\cmd\git.exe'
        $arm64 = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop).Architecture -contains 12
        $level = if ($env:config -like 'trusted-*') { 3 } else { 1 }
        if ($arm64 -or $env:GECKO_GIT_SEED_REVISION) {
            $state = Get-Content 'C:\worker-runner\directory-caches.json' -Raw -ErrorAction Stop | ConvertFrom-Json
        }
    }

    It 'Contains the selected Hg history in each expected store' {
        $sharebases = @('C:\hg-shared')
        if ($arm64) {
            $sharebases = foreach ($name in @("gecko-level-$level-checkouts", "gecko-level-$level-checkouts-sparse", 'relops-level-3-checkouts-sparse')) {
                @($state.$name).Count | Should -Be 1
                $state.$name[0].key | Should -BeExactly $name
                $state.$name[0].location | Should -BeExactly "C:\caches\$name"
                $state.$name[0].created | Should -Not -BeNullOrEmpty
                "C:\caches\$name\hg-store"
            }
        }
        foreach ($sharebase in $sharebases) {
            $stores = @(Get-ChildItem -LiteralPath $sharebase -Directory -ErrorAction Stop)
            $stores.Count | Should -Be 1
            $store = $stores[0].FullName
            $stores[0].Name | Should -Match '^[0-9a-f]{40}$'
            (Get-Content "$store\.hg\worker-image-seed" -Raw -ErrorAction Stop).Trim() | Should -BeExactly $env:GECKO_HG_SEED_REVISION
            "$store\.hg\sharedpath" | Should -Not -Exist
            & $hg -R $store log -r $env:GECKO_HG_SEED_REVISION -T '{node}' | Should -BeExactly $env:GECKO_HG_SEED_REVISION
            $LASTEXITCODE | Should -Be 0
            if (-not $arm64) {
                foreach ($relative in @('.hg\store\00changelog.i', '.hg\worker-image-seed')) {
                    $acl = Get-Acl -LiteralPath "$store\$relative" -ErrorAction Stop
                    $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value | Should -Be 'S-1-5-18'
                    @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | Where-Object {
                        $_.IdentityReference.Value -eq 'S-1-1-0' -and $_.IsInherited -and
                        $_.AccessControlType -eq 'Allow' -and
                        ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -eq
                            [System.Security.AccessControl.FileSystemRights]::FullControl
                    }).Count | Should -BeGreaterThan 0
                }
            }
        }
    }

    It 'Registers full and shallow Git caches at the selected commit' -Skip:([string]::IsNullOrWhiteSpace($env:GECKO_GIT_SEED_REVISION)) {
        foreach ($suffix in @('', '-shallow')) {
            $name = "gecko-level-$level-checkouts-git$suffix"
            @($state.$name).Count | Should -Be 1
            $state.$name[0].key | Should -BeExactly $name
            $state.$name[0].location | Should -BeExactly "C:\caches\$name"
            $state.$name[0].created | Should -Not -BeNullOrEmpty
            $repo = "C:\caches\$name\src"
            (Get-Content "$repo\.git\worker-image-seed" -Raw -ErrorAction Stop).Trim() | Should -BeExactly $env:GECKO_GIT_SEED_REVISION
            & $git -C $repo rev-parse --verify 'HEAD^{commit}' | Should -BeExactly $env:GECKO_GIT_SEED_REVISION
            $LASTEXITCODE | Should -Be 0
            & $git -C $repo remote get-url origin | Should -BeExactly 'https://github.com/mozilla-firefox/firefox'
            $LASTEXITCODE | Should -Be 0
            (Test-Path "$repo\.git\shallow") | Should -Be ($suffix -eq '-shallow')
            "$repo\.git\objects\info\alternates" | Should -Not -Exist
            @(Get-ChildItem -LiteralPath $repo -Force | Where-Object Name -ne '.git').Count | Should -Be 0
        }
    }
}
