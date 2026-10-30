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

Describe 'Gecko image seed' -Skip:([string]::IsNullOrWhiteSpace($env:GECKO_GIT_SEED_REVISION)) {
    BeforeAll {
        $git = 'C:\Program Files\Git\cmd\git.exe'
        $level = if ($env:config -like 'trusted-*') { 3 } else { 1 }
        $state = Get-Content 'C:\worker-runner\directory-caches.json' -Raw -ErrorAction Stop | ConvertFrom-Json
    }

    It 'Registers full and shallow Git caches at the selected commit' {
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
