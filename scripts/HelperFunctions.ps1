function Get-WorkerPoolId {
    (Get-ItemProperty "HKLM:\SOFTWARE\Mozilla\ronin_puppet").worker_pool_id
}

function Get-HieraRoleData {
    param(
        [System.IO.FileInfo]
        [ValidateScript({
                if ( -Not ($_ | Test-Path) ) {
                    throw "File or folder does not exist"
                }
                if ($_ -notmatch "(\.yml|\.yaml)") {
                    throw "The file specified in the path argument must be either of type yml or yaml"
                }
                return $true
            })]
        $Path
    )
    
    ConvertFrom-Yaml (get-Content $Path -Raw)
}

function Get-WinFactsBootStrapStage {
    if (test-path "HKLM:\SOFTWARE\Mozilla\ronin_puppet") {
        $bootstrap_stage = (Get-ItemProperty "HKLM:\SOFTWARE\Mozilla\ronin_puppet").bootstrap_stage
        [PSCustomObject]@{
            custom_win_bootstrap_stage = $bootstrap_stage
        }
    }
    else {
        throw "HKLM:\SOFTWARE\Mozilla\ronin_puppe not found!"
    }
}

function Get-WinFactsCustomOS {
    # Source Code Form is subject to the terms of the Mozilla Public
    # License, v. 2.0. If a copy of the MPL was not distributed with this
    # file, You can obtain one at http://mozilla.org/MPL/2.0/.

    # Custom facts based off OS details that are not included in the default facts

    # Windows release ID.
    # From time to time we need to have the different releases of the same OS version
    $release_key = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion')
    $release_id = $release_key.ReleaseId
    $win_os_build = [System.Environment]::OSVersion.Version.build

    # OS caption
    # Used to determine which KMS license for cloud workers
    $caption = ((Get-WmiObject Win32_OperatingSystem).caption)
    $caption = $caption.ToLower()
    $os_caption = $caption -replace ' ', '_'
    # Windows activation status
    $status = (Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "Name like 'Windows%'" | where PartialProductKey).licensestatus

    If ($status -eq '1') {
        $kms_status = "activated"
    }
    else {
        $kms_status = "needs_activation"
    }

    # Administrator SID
    $administrator_info = Get-WmiObject win32_useraccount -Filter "name = 'Administrator'"
    $win_admin_sid = $administrator_info.sid

    # Network profile
    # https://bugzilla.mozilla.org/show_bug.cgi?id=1563287
    $NetCategory = Get-NetConnectionProfile | select NetworkCategory

    if ($NetCategory -like '*private*') {
        $NetworkCategory = "private"
    }
    else {
        $NetworkCategory = "other"
    }

    # Firewall status
    $firewall_status = (netsh advfirewall show domain state)

    if ($firewall_status -like "*off*") {
        $firewall_status = "off"
    }
    else {
        $firewall_status = "running"
    }

    # Base image ID
    $role = (Get-ItemProperty "HKLM:\SOFTWARE\Mozilla\ronin_puppet").role

    # Get worker pool ID
    $worker_pool_id = (Get-ItemProperty "HKLM:\SOFTWARE\Mozilla\ronin_puppet").worker_pool_id

    if ($worker_pool_id -like "*gpu*") {
        $gpu = 'yes'
    }
    else {
        $gpu = 'no'
    }

    if ($os_caption -like "*windows_10*") {
        $os_version = ( -join ( "win_10_", $release_id))
        $purpose = "tester"
    }
    elseif ($os_caption -like "*windows_11*") {
        $os_version = ( -join ( "win_11_", $release_id))
        $purpose = "tester"
    }
    elseif ($os_caption -like "*2012*") {
        $os_version = "win_2012"
        $purpose = 'builder'
    }
    elseif ($os_caption -like "*2022*") {
        $os_version = ( -join ( "win_2022_", $release_id))
        $purpose = 'builder'
    }
    else {
        $os_version = $null
    }

    [PSCustomObject]@{
        custom_win_release_id      = $release_id
        custom_win_os_caption      = $os_caption
        custom_win_os_version      = $os_version
        custom_win_kms_activated   = $kms_status
        custom_win_admin_sid       = $win_admin_sid
        custom_win_net_category    = $NetworkCategory
        custom_win_firewall_status = $firewall_status
        custom_win_role            = $role
        custom_win_worker_pool_id  = $worker_pool_id
        custom_win_gpu             = $gpu
        custom_win_purpose         = $purpose
    }
}

Function Get-WinFactsDirectories {
    $systemdrive = $env:systemdrive
    $system32 = "$systemdrive\windows\system32"
    $programdata = $env:programdata
    $programfiles = $env:ProgramW6432
    $programfilesx86 = "$systemdrive\Program Files (x86)"

    # Bug list
    # https://bugzilla.mozilla.org/show_bug.cgi?id=1520855
    [PSCustomObject]@{
        custom_win_systemdrive       = $env:systemdrive
        custom_win_system32          = $system32
        custom_win_programdata       = $programdata
        custom_win_programfiles      = $programfiles
        custom_win_programfilesx86   = $programfilesx86
        custom_win_roninprogramdata  = "$($programdata)\PuppetLabs\ronin"
        custom_win_roninsemaphoredir = "$($programdata)\PuppetLabs\ronin\semaphore"
        custom_win_roninslogdir      = "$($systemdrive)\logs"
        custom_win_temp_dir          = "$($systemdrive)\Windows\Temp"
        custom_win_third_party       = "$($systemdrive)\third_party"
    }
}

Function Get-WinFactsDrives {
    [PSCustomObject]@{
        custom_win_z_drive = if ((Test-Path Z:\)) { "exists" } else { $null }
        custom_win_y_drive = if ((Test-Path Y:\)) { "exists" } else { $null }
    }
}

Function Get-WinFactsLocation {
    $DhcpDomain = ((Get-ItemProperty 'HKLM:SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Parameters').'DhcpDomain')
    $NVDomain = ((Get-ItemProperty 'HKLM:SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Parameters').'NV Domain')

    if ($NVDomain -like "*bitbar*") {
        $location = "bitbar"
        $mozspace = "bitbar"
    }
    elseif ($DhcpDomain -like "*ec2*") {
        $location = "aws"
    }
    elseif ($DhcpDomain -like "*cloudapp.net") {
        $location = "azure"
    }
    elseif ($DhcpDomain -like "*microsoft*") {
        $location = "azure"
    }
    else {
        $location = "datacenter"
    }

    if ($location -eq "datacenter") {
        if ($DhcpDomain -like "*MDC1*") {
            $mozspace = "mdc1"
        }
        elseif ($DhcpDomain -like "*MDC2*") {
            $mozspace = "mdc2"
        }
        elseif ($DhcpDomain -like "*MTV2*") {
            $mozspace = "mtv2"
        }
        else {
            $mozspace = "unkown"
        }
    }

    [PSCustomObject]@{
        custom_win_location = $location
        custom_win_mozspace = $mozspace
    }
}

function Get-WinFactsMozillaBuild {
    # This Source Code Form is subject to the terms of the Mozilla Public
    # License, v. 2.0. If a copy of the MPL was not distributed with this
    # file, You can obtain one at http://mozilla.org/MPL/2.0/.

    # This is specific for creation of facts for items isntalled
    # by the Mozilla Build package

    # these are needed becuase we are unable to run validation commands
    # or do a direct version validation of application

    $mozbld_file = "$env:systemdrive\mozilla-build\VERSION"
    $hg_file = "$env:ProgramW6432\Mercurial\hg.exe"
    $python3_file = "$env:systemdrive\mozilla-build\python3\python3.exe"
    $zstandard = "$env:systemdrive\mozilla-build\python3\lib\site-packages\zstandard"

    # Mozilla Build
    # Needed in roles_profiles::profiles::mozilla_build
    if (Test-Path $mozbld_file) {
        $mozbld_ver = (get-content $mozbld_file)
    }
    else {
        $mozbld_ver = 0.0.0
    }

    # Mercurial
    # Needed in roles_profiles::profiles::mozilla_build
    if (Test-Path $hg_file) {
        $hg_object = Get-InstalledSoftware | Where-Object { $PSItem.displayname -match "Mercurial" }
        $hg_ver = $hg_object.DisplayVersion
    }
    else {
        $hg_ver = 0.0.0
    }

    # Python 3 Pip
    if (Test-Path $python3_file) {
        $pip_version = (C:\mozilla-build\python3\python3.exe -m pip --version)
        $py3_pip_version = ($pip_version -split " ")[1]
    }
    else {
        $py3_pip_version = 0.0.0
    }

    # Pyhton 3 zstandard
    if (Test-Path $python3_file) {
        $zstandard_info = (C:\mozilla-build\python3\python3.exe -m pip show zstandard)
        $zstandard_version = [regex]::Matches($zstandard_info, "(\d+\.\d+\.\d+)").value
    }
    else {
        $zstandard_version = 0.0.0
    }
    
    [PSCustomObject]@{
        custom_win_py3_pip_version       = $py3_pip_version
        custom_win_mozbld_vesion         = $mozbld_ver
        custom_win_hg_version            = $hg_ver
        custom_win_py3_zstandard_version = $zstandard_version
    }
    
}

function Get-WinFactsOtherApps {
    $git = Get-Command "git.exe"
    if ($git) {
        $git_ver = "{0}.{1}.{2}" -f $git.Version.Major, $git.Version.Minor, $git.Version.Build
    }
    else {
        $git_ver = 0.0.0
    }
    
    [PSCustomObject]@{
        custom_win_git_version = $git_ver
    }
}

function Get-WinFactsSSHd {
    $service = 'sshd'

    $result = (Get-Service $service -ErrorAction SilentlyContinue)
    if ($null -eq $result) {
        $sshd_present = 'not_installed'
    }
    else {
        $sshd_present = 'installed'
    }

    [PSCustomObject]@{
        custom_win_sshd = $sshd_present
    }
}

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

Function Invoke-RoninTest {
    [CmdletBinding()]
    param (
        [Parameter()]
        [String]
        $Test,

        [String[]]
        $Tags,

        [String[]]
        $ExcludeTag,

        [Switch]
        $PassThru
    )
    $Container = New-PesterContainer -Path $test
    $config = New-PesterConfiguration
    $config.Run.Container = $Container
    $config.Filter.Tag = $Tags
    $config.TestResult.Enabled = $true
    $config.Output.Verbosity = "Detailed"
    if ($ExcludeTag) {
        $config.Filter.ExcludeTag = $ExcludeTag
    }
    if ($PassThru) {
        $config.Run.Passthru = $true
    }
    Invoke-Pester -Configuration $config
}
