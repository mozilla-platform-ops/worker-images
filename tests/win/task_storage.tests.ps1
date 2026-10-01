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
