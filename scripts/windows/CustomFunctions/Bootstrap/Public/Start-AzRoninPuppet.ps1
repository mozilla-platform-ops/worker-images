function Start-AzRoninPuppet {
    param (
        [int] $exit,
        [int] $last_exit = (Get-ItemProperty "HKLM:\SOFTWARE\Mozilla\ronin_puppet").last_run_exit,
        [string] $nodes_def = "$env:systemdrive\ronin\manifests\nodes\odes.pp",
        [string] $puppetfile = "$env:systemdrive\ronin\Puppetfile",
        [string] $logdir = "$env:systemdrive\logs",
        [string] $ed_key = "$env:systemdrive\generic-worker\ed25519-private.key",
        [string] $datetime = (get-date -format yyyyMMdd-HHmm),
        [string] $mozilla_key = "HKLM:\SOFTWARE\Mozilla\",
        [string] $ronnin_key = "$mozilla_key\ronin_puppet",
        [string] $worker_pool = (Get-ItemProperty "HKLM:\SOFTWARE\Mozilla\ronin_puppet").worker_pool_id,
        [string] $stage = (Get-ItemProperty -path "HKLM:\SOFTWARE\Mozilla\ronin_puppet").bootstrap_stage,
        [string] $deploymentId = $ENV:deploymentId
    )
    begin {
        Write-Log -message ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'
        Write-Host ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime())
    }
    process {
        ## Set azcopy vars
        $ENV:AZCOPY_AUTO_LOGIN_TYPE = "SPN"
        $ENV:AZCOPY_SPA_APPLICATION_ID = $ENV:application_id
        $ENV:AZCOPY_SPA_CLIENT_SECRET = $ENV:client_secret
        $ENV:AZCOPY_TENANT_ID = $ENV:tenant_id

        Set-Location $env:systemdrive\ronin
        If ( -Not (test-path $logdir\old)) {
            New-Item -ItemType Directory -Force -Path $logdir\old
        }
        Write-Log -message ('{0} :: Ronin Puppet HEAD is set to {1}' -f $($MyInvocation.MyCommand.Name), $deploymentID) -severity 'DEBUG'
        Write-host ('{0} :: Ronin Puppet HEAD is set to {1}' -f $($MyInvocation.MyCommand.Name), $deploymentID)

        Set-ItemProperty -Path "HKLM:\SOFTWARE\Mozilla\ronin_puppet" -Name 'bootstrap_stage' -Value 'inprogress'

        # Setting Env variabes for PuppetFile install and Puppet run
        # The ssl variables are needed for R10k
        Write-Log -message ('{0} :: Setting Puppet enviroment.' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'
        Write-host ('{0} :: Setting Puppet enviroment.' -f $($MyInvocation.MyCommand.Name))

        $env:path = "$env:programfiles\Puppet Labs\Puppet\bin;$env:path"
        $env:SSL_CERT_FILE = "$env:programfiles\Puppet Labs\Puppet\puppet\ssl\cert.pem"
        $env:SSL_CERT_DIR = "$env:programfiles\Puppet Labs\Puppet\puppet\ssl"
        $env:FACTER_env_windows_installdir = "$env:programfiles\Puppet Labs\Puppet"
        $env:HOMEPATH = "\Users\Administrator"
        $env:HOMEDRIVE = "C:"
        $env:PL_BASEDIR = "$env:programfiles\Puppet Labs\Puppet"
        $env:PUPPET_DIR = "$env:programfiles\Puppet Labs\Puppet"
        $env:RUBYLIB = "$env:programfiles\Puppet Labs\Puppet\lib"
        $env:USERNAME = "Administrator"
        $env:USERPROFILE = "$env:systemdrive\Users\Administrator"

        Write-Log -message ('{0} :: Moving old logs.' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'
        Write-host ('{0} :: Moving old logs.' -f $($MyInvocation.MyCommand.Name))
        Get-ChildItem -Path $logdir\*.json -Recurse -ErrorAction SilentlyContinue | Move-Item -Destination $logdir\old -ErrorAction SilentlyContinue
        $logDate = $(get-date -format yyyyMMdd-HHmm)
        $LogDestination = ("$env:systemdrive\logs\{0}-{1}-bootstrap-puppet.json" -f $ENV:COMPUTERNAME,$logdate)
        ## create a step where we're recording the time it takes to run puppet apply
        $stopWatch = New-Object -TypeName System.Diagnostics.Stopwatch
        ## start the timer
        $stopWatch.Start()
        puppet apply manifests\nodes.pp --onetime --verbose --no-daemonize --no-usecacheonfailure --detailed-exitcodes --no-splay --show_diff --modulepath=modules`;r10k_modules --hiera_config=hiera.yaml --logdest $LogDestination
        [int]$puppet_exit = $LastExitCode
        ## stop the timer
        $stopWatch.Stop()
        ## get the time it took to run puppet apply
        $time = $stopWatch.Elapsed
        Write-host ('{0} :: Puppet apply took - {1} minutes, {2} seconds to complete' -f $($MyInvocation.MyCommand.Name),$time.Minutes, $time.Seconds)
        Write-Log -message  ('{0} :: Puppet apply took - {1} minutes, {2} seconds to complete' -f $($MyInvocation.MyCommand.Name),$time.Minutes, $time.Seconds) -severity 'DEBUG'
        ## https://www.puppet.com/docs/puppet/6/man/apply.html#options
        
        switch ($puppet_exit) {
            0 {
                Set-ItemProperty -Path $ronnin_key -name last_run_exit -value $puppet_exit
                Set-ItemProperty -Path $ronnin_key -Name 'bootstrap_stage' -Value 'complete'
                #Move-StrapPuppetLogs
                if ($worker_pool -like "trusted*") {
                    if (Test-Path -Path $ed_key) {
                        Remove-Item $ed_key -force
                    }
                    while (!(Test-Path $ed_key)) {
                        Write-Log -message  ('{0} :: Trusted image. Waiting on CoT key. Human intervention needed.' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'
                        Start-Sleep -seconds 15
                    }
                    # Provide a window for the file to be writen
                    Start-Sleep -seconds 30
                    Write-Log -message  ('{0} :: Trusted image. Blocking livelog outbound access.' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'
                    New-NetFirewallRule -DisplayName "Block LiveLog" -Direction Outbound -Program "c:\generic-worker\livelog.exe" -Action block
                }
                exit 0
            }
            1 {
                Write-Log -message ('{0} :: Puppet apply failed :: Error code {1}' -f $($MyInvocation.MyCommand.Name), $puppet_exit) -severity 'DEBUG'
                Write-Host ('{0} :: Puppet apply failed :: Error code {1}' -f $($MyInvocation.MyCommand.Name), $puppet_exit)
                Set-ItemProperty -Path $ronnin_key -name "last_run_exit" -value $puppet_exit
                ## The JSON file isn't formatted correctly, so add a ] to complete the json formatting and then output warnings or errors
                Add-Content $LogDestination "`n]" 
                $log = Get-Content $LogDestination | ConvertFrom-Json 
                $log | Where-Object {
                    $psitem.Level -match "warning|err" -and $_.message -notmatch "Client Certificate|Private Key"
                } | ForEach-Object {
                    $data = $psitem
                    Write-Log -message ('{0} :: Puppet File {1}' -f $($MyInvocation.MyCommand.Name), $data.file) -severity 'DEBUG'
                    Write-Log -message ('{0} :: Puppet Message {1}' -f $($MyInvocation.MyCommand.Name), $data.message) -severity 'DEBUG'
                    Write-Log -message ('{0} :: Puppet Level {1}' -f $($MyInvocation.MyCommand.Name), $data.level) -severity 'DEBUG'
                    Write-Log -message ('{0} :: Puppet Line {1}' -f $($MyInvocation.MyCommand.Name), $data.line) -severity 'DEBUG'
                    Write-Log -message ('{0} :: Puppet Source {1}' -f $($MyInvocation.MyCommand.Name), $data.source) -severity 'DEBUG'
                }

                ## Authenticate
                $ENV:AZCOPY_AUTO_LOGIN_TYPE = "SPN"
                $ENV:AZCOPY_SPA_APPLICATION_ID = $ENV:application_id
                $ENV:AZCOPY_SPA_CLIENT_SECRET = $ENV:client_secret
                $ENV:AZCOPY_TENANT_ID = $ENV:tenant_id

                Start-Process -FilePath "$ENV:systemdrive\azcopy.exe" -ArgumentList @(
                    "copy",
                    $LogDestination,
                    "https://roninpuppetassets.blob.core.windows.net/packer"
                ) -Wait -NoNewWindow

                Move-StrapPuppetLogs
                exit 1
            }
            2 {
                Write-Log -message ('{0} :: Puppet apply succeeded, and some resources were changed :: Error code {1} :: {2:o}' -f $($MyInvocation.MyCommand.Name), $puppet_exit,(Get-Date).ToUniversalTime()) -severity 'DEBUG'
                Write-Host ('{0} :: Puppet apply succeeded, and some resources were changed :: Error code {1} :: {2:o}' -f $($MyInvocation.MyCommand.Name), $puppet_exit,(Get-Date).ToUniversalTime())
                Set-ItemProperty -Path $ronnin_key -name last_run_exit -value $puppet_exit
                Set-ItemProperty -Path $ronnin_key -Name 'bootstrap_stage' -Value 'complete'
                #Move-StrapPuppetLogs
                if ($worker_pool -like "trusted*") {
                    if (Test-Path -Path $ed_key) {
                        Remove-Item $ed_key -force
                    }
                    while (!(Test-Path $ed_key)) {
                        Write-Log -message  ('{0} :: Trusted image. Waiting on CoT key. Human intervention needed.' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'
                        Start-Sleep -seconds 15
                    }
                    # Provide a window for the file to be writen
                    Start-Sleep -seconds 30
                    Write-Log -message  ('{0} :: Trusted image. Blocking livelog outbound access.' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'
                    New-NetFirewallRule -DisplayName "Block LiveLog" -Direction Outbound -Program "c:\generic-worker\livelog.exe" -Action block
                }
                exit 2
            }
            4 {
                Write-Log -message ('{0} :: Puppet apply succeeded, but some resources failed :: Error code {1}' -f $($MyInvocation.MyCommand.Name), $puppet_exit) -severity 'DEBUG'
                Write-Host ('{0} :: Puppet apply succeeded, but some resources failed :: Error code {1}' -f $($MyInvocation.MyCommand.Name), $puppet_exit)
                Set-ItemProperty -Path $ronnin_key -name last_run_exit -value $puppet_exit
                ## The JSON file isn't formatted correctly, so add a ] to complete the json formatting and then output warnings or errors
                Add-Content $LogDestination "`n]" 
                $log = Get-Content $LogDestination | ConvertFrom-Json 
                $log | Where-Object {
                    $psitem.Level -match "warning|err" -and $_.message -notmatch "Client Certificate|Private Key"
                } | ForEach-Object {
                    $data = $psitem
                    Write-Log -message ('{0} :: Puppet File {1}' -f $($MyInvocation.MyCommand.Name), $data.file) -severity 'DEBUG'
                    Write-Log -message ('{0} :: Puppet Message {1}' -f $($MyInvocation.MyCommand.Name), $data.message) -severity 'DEBUG'
                    Write-Log -message ('{0} :: Puppet Level {1}' -f $($MyInvocation.MyCommand.Name), $data.level) -severity 'DEBUG'
                    Write-Log -message ('{0} :: Puppet Line {1}' -f $($MyInvocation.MyCommand.Name), $data.line) -severity 'DEBUG'
                    Write-Log -message ('{0} :: Puppet Source {1}' -f $($MyInvocation.MyCommand.Name), $data.source) -severity 'DEBUG'
                }

                ## Authenticate
                $ENV:AZCOPY_AUTO_LOGIN_TYPE = "SPN"
                $ENV:AZCOPY_SPA_APPLICATION_ID = $ENV:application_id
                $ENV:AZCOPY_SPA_CLIENT_SECRET = $ENV:client_secret
                $ENV:AZCOPY_TENANT_ID = $ENV:tenant_id

                Start-Process -FilePath "$ENV:systemdrive\azcopy.exe" -ArgumentList @(
                    "copy",
                    $LogDestination,
                    "https://roninpuppetassets.blob.core.windows.net/packer"
                ) -Wait -NoNewWindow

                Move-StrapPuppetLogs
                exit 4
            }
            6 {
                Write-Log -message ('{0} :: Puppet apply succeeded, but included changes and failures :: Error code {1}' -f $($MyInvocation.MyCommand.Name), $puppet_exit) -severity 'DEBUG'
                Write-Host ('{0} :: Puppet apply succeeded, but included changes and failures :: Error code {1}' -f $($MyInvocation.MyCommand.Name), $puppet_exit)
                Set-ItemProperty -Path $ronnin_key -name last_run_exit -value $puppet_exit
                ## The JSON file isn't formatted correctly, so add a ] to complete the json formatting and then output warnings or errors
                Add-Content $LogDestination "`n]" 
                $log = Get-Content $LogDestination | ConvertFrom-Json 
                $log | Where-Object {
                    $psitem.Level -match "warning|err" -and $_.message -notmatch "Client Certificate|Private Key"
                } | ForEach-Object {
                    $data = $psitem
                    Write-Log -message ('{0} :: Puppet File {1}' -f $($MyInvocation.MyCommand.Name), $data.file) -severity 'DEBUG'
                    Write-Log -message ('{0} :: Puppet Message {1}' -f $($MyInvocation.MyCommand.Name), $data.message) -severity 'DEBUG'
                    Write-Log -message ('{0} :: Puppet Level {1}' -f $($MyInvocation.MyCommand.Name), $data.level) -severity 'DEBUG'
                    Write-Log -message ('{0} :: Puppet Line {1}' -f $($MyInvocation.MyCommand.Name), $data.line) -severity 'DEBUG'
                    Write-Log -message ('{0} :: Puppet Source {1}' -f $($MyInvocation.MyCommand.Name), $data.source) -severity 'DEBUG'
                }

                ## Authenticate
                $ENV:AZCOPY_AUTO_LOGIN_TYPE = "SPN"
                $ENV:AZCOPY_SPA_APPLICATION_ID = $ENV:application_id
                $ENV:AZCOPY_SPA_CLIENT_SECRET = $ENV:client_secret
                $ENV:AZCOPY_TENANT_ID = $ENV:tenant_id

                Start-Process -FilePath "$ENV:systemdrive\azcopy.exe" -ArgumentList @(
                    "copy",
                    $LogDestination,
                    "https://roninpuppetassets.blob.core.windows.net/packer"
                ) -Wait -NoNewWindow

                Move-StrapPuppetLogs
                exit 6
            }
            Default {
                Write-Log -message  ('{0} :: Unable to determine state post Puppet apply :: Error code {1}' -f $($MyInvocation.MyCommand.Name), $puppet_exit) -severity 'DEBUG'
                Set-ItemProperty -Path $ronnin_key -name last_run_exit -value $last_exit
                #Start-sleep -s 300
                #Move-StrapPuppetLogs
                exit 1
            }
        }
    }
    end {
        Write-Log -message ('{0} :: end - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    }
}
