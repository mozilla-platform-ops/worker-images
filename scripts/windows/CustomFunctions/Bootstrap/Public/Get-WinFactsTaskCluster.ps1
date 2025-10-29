function Get-WinFactsTaskCluster {
    $gw_file = "$env:systemdrive\generic-worker\generic-worker.exe"
    $runner_file = "$env:systemdrive\worker-runner\start-worker.exe"
    $taskcluster_proxy_file = "$env:systemdrive\generic-worker\taskcluster-proxy.exe"

    # Generic-worker
    $gw_service = 'Generic Worker'

    If (Get-Service $gw_service -ErrorAction SilentlyContinue) {
        $gw_service = "present"
    }
    Else {
        $gw_service = "missing"
    }

    if (Test-Path $gw_file) {
        $gw_version = (Select-String -Pattern "\d+\.\d+\.\d+" -InputObject (cmd /c $gw_file --version)).Matches.value
    }
    else {
        $gw_version = 0.0.0
    }

    # worker-runner
    $runner_service = 'worker-runner'
    If (Get-Service $runner_service -ErrorAction SilentlyContinue) {
        $runner_service = "present"
    }
    Else {
        $runner_service = "missing"
    }

    if (Test-Path $runner_file) {
        $runner_version = (Select-String -Pattern "\d+\.\d+\.\d+" -InputObject (cmd /c $runner_file --version)).Matches.value
    }
    else {
        $runner_version = 0.0.0
    }

    # Taskcluster proxy
    if (Test-Path $taskcluster_proxy_file) {
        $proxy_version = (Select-String -Pattern "\d+\.\d+\.\d+" -InputObject (cmd /c $taskcluster_proxy_file --version)).Matches.value
    }
    else {
        $proxy_version = 0.0.0
    }

    # workerType is set during proviosning (This may only be for hardware) And OLD.
    if (test-path "HKLM:\SOFTWARE\Mozilla\ronin_puppet") {
        $gw_workertype = (Get-ItemProperty "HKLM:\SOFTWARE\Mozilla\ronin_puppet").workerType
    }

    # Get worker pool ID
    $worker_pool_id = (Get-ItemProperty "HKLM:\SOFTWARE\Mozilla\ronin_puppet").worker_pool_id

    [PSCustomObject]@{
        custom_win_genericworker_service     = $gw_service
        custom_win_genericworker_version     = $gw_version
        custom_win_runner_service            = $runner_service
        custom_win_runner_version            = $runner_version
        custom_win_taskcluster_proxy_version = $proxy_version
        custom_win_gw_workerType             = $gw_workertype
        custom_win_worker_pool_id            = $worker_pool_id
    }
}