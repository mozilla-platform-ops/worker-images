Describe "C: task storage" {
    It "Configures task and cache paths on C:" {
        $config = Get-Content 'C:\worker-runner\runner.yml' -Raw | ConvertFrom-Yaml
        $config.workerConfig.tasksDir | Should -BeExactly 'C:\Users'
        $config.workerConfig.cachesDir | Should -BeExactly 'C:\caches'
        $config.workerConfig.downloadsDir | Should -BeExactly 'C:\downloads'
        Get-ItemPropertyValue 'HKLM:\SOFTWARE\Mozilla\ronin_puppet' -Name task_drive | Should -BeExactly 'C:'
    }

    It "Configures the pagefile on C:" {
        $paging = Get-ItemPropertyValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name PagingFiles
        @($paging) | Should -Contain 'C:\pagefile.sys 8192 8192'
        @($paging | Where-Object { $_ -like 'D:*' }).Count | Should -Be 0
    }
}
