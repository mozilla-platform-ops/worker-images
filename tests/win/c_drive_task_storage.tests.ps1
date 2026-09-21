# Selected by Windows alpha images that use C: task storage.
Describe "C: task storage" {
    It "Configures task and cache paths on C:" {
        $config = Get-Content 'C:\worker-runner\runner.yml' -Raw | ConvertFrom-Yaml
        $config.workerConfig.tasksDir | Should -BeExactly 'C:\tasks'
        $config.workerConfig.cachesDir | Should -BeExactly 'C:\caches'
        $config.workerConfig.downloadsDir | Should -BeExactly 'C:\downloads'
        Get-ItemPropertyValue 'HKLM:\SOFTWARE\Mozilla\ronin_puppet' -Name task_drive | Should -BeExactly 'C:'
    }

    It "Configures the pagefile on C:" {
        $paging = Get-ItemPropertyValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name PagingFiles
        @($paging) | Should -Contain 'C:\pagefile.sys 8192 8192'
        @($paging | Where-Object { $_ -like 'D:*' }).Count | Should -Be 0
    }

    It "Skips temporary disk initialization for C: task storage" {
        . 'C:\ProgramData\PuppetLabs\ronin\maintainsystem.ps1'
        Mock Write-Log {}
        $taskDrive = Get-ItemPropertyValue 'HKLM:\SOFTWARE\Mozilla\ronin_puppet' -Name task_drive
        # A missing setup script makes this fail if startup requires D:.
        Ensure-AzureNvmeTemporaryDrive -vmSize 'Standard_F8alds_v7' -TaskDrive $taskDrive -scriptPath "$TestDrive\missing-disk-setup.ps1"
        Test-AzureNvmeTemporaryDriveRequired -vmSize 'Standard_F8alds_v7' -TaskDrive 'D:' | Should -BeTrue
    }
}
