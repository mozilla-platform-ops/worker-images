function Write-Log {
    param (
        [string] $message,
        [string] $severity = 'INFO',
        [string] $source = 'BootStrap',
        [string] $logName = 'Application'
    )
    if (!([Diagnostics.EventLog]::Exists($logName)) -or !([Diagnostics.EventLog]::SourceExists($source))) {
        New-EventLog -LogName $logName -Source $source
    }
    switch ($severity) {
        'DEBUG' {
            $entryType = 'SuccessAudit'
            $eventId = 2
            break
        }
        'WARN' {
            $entryType = 'Warning'
            $eventId = 3
            break
        }
        'ERROR' {
            $entryType = 'Error'
            $eventId = 4
            break
        }
        default {
            $entryType = 'Information'
            $eventId = 1
            break
        }
    }
    Write-EventLog -LogName $logName -Source $source -EntryType $entryType -Category 0 -EventID $eventId -Message $message
    if ([Environment]::UserInteractive) {
        $fc = @{ 'Information' = 'White'; 'Error' = 'Red'; 'Warning' = 'DarkYellow'; 'SuccessAudit' = 'DarkGray' }[$entryType]
        Write-Host  -object $message -ForegroundColor $fc
    }
}

function Set-PXE {
    Import-Module Microsoft.Windows.Bcd.Cmdlets
    $data = (Get-BcdStore).entries | ForEach-Object {
        $d = ($_.Elements | Where-Object { $_.Name -eq "Description" }).value
        if ($d -match "IPv4") {
            $PSItem
        }
    }
    bcdedit /set "{fwbootmgr}" BOOTSEQUENCE "{$($data.Identifier.Guid)}"
    Restart-Computer -Force
}

function Test-ConnectionUntilOnline {
    param (
        [string]$Hostname = "www.google.com",
        [int]$Interval = 5,
        [int]$TotalTime = 120
    )

    $elapsedTime = 0

    while ($elapsedTime -lt $totalTime) {
        if (Test-Connection -ComputerName $hostname -Count 1 -Quiet) {
            Write-Log -message ('{0} :: {1} is online! Continuing.' -f $($MyInvocation.MyCommand.Name), $ENV:COMPUTERNAME) -severity 'DEBUG'
            return
        }
        else {
            Write-Log -message ('{0} :: {1} is not online, checking again in {2}' -f $($MyInvocation.MyCommand.Name), $ENV:COMPUTERNAME, $interval) -severity 'DEBUG'
            Start-Sleep -Seconds $interval
            $elapsedTime += $interval
        }
    }

    Write-Log -message ('{0} :: {1} did not come online within {2} seconds' -f $($MyInvocation.MyCommand.Name), $ENV:COMPUTERNAME, $totalTime) -severity 'DEBUG'
    throw "Connection timeout."
}

function Invoke-DownloadWithRetry {
    <#
    .SYNOPSIS
        Downloads a file from a given URL with retry functionality.

    .DESCRIPTION
        The Invoke-DownloadWithRetry function downloads a file from the specified URL
        to the specified path. It includes retry functionality in case the download fails.

    .PARAMETER Url
        The URL of the file to download.

    .PARAMETER Path
        The path where the downloaded file will be saved. If not provided, a temporary path
        will be used.

    .EXAMPLE
        Invoke-DownloadWithRetry -Url "https://example.com/file.zip" -Path "C:\Downloads\file.zip"
        Downloads the file from the specified URL and saves it to the specified path.

    .EXAMPLE
        Invoke-DownloadWithRetry -Url "https://example.com/file.zip"
        Downloads the file from the specified URL and saves it to a temporary path.

    .OUTPUTS
        The path where the downloaded file is saved.
    #>

    Param
    (
        [Parameter(Mandatory)]
        [string] $Url,
        [Alias("Destination")]
        [string] $Path
    )

    if (-not $Path) {
        $invalidChars = [IO.Path]::GetInvalidFileNameChars() -join ''
        $re = "[{0}]" -f [RegEx]::Escape($invalidChars)
        $fileName = [IO.Path]::GetFileName($Url) -replace $re

        if ([String]::IsNullOrEmpty($fileName)) {
            $fileName = [System.IO.Path]::GetRandomFileName()
        }
        $Path = Join-Path -Path "${env:Temp}" -ChildPath $fileName
    }

    Write-Host "Downloading package from $Url to $Path..."
    Write-Log -message ('{0} :: Downloading {1} to {2} - {3:o}' -f $($MyInvocation.MyCommand.Name), $url, $path, (Get-Date).ToUniversalTime()) -severity 'DEBUG'

    $interval = 30
    $downloadStartTime = Get-Date
    for ($retries = 20; $retries -gt 0; $retries--) {
        try {
            $attemptStartTime = Get-Date
            (New-Object System.Net.WebClient).DownloadFile($Url, $Path)
            $attemptSeconds = [math]::Round(($(Get-Date) - $attemptStartTime).TotalSeconds, 2)
            Write-Host "Package downloaded in $attemptSeconds seconds"
            Write-Log -message ('{0} :: Package downloaded in {1} seconds - {2:o}' -f $($MyInvocation.MyCommand.Name), $attemptSeconds, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
            break
        }
        catch {
            $attemptSeconds = [math]::Round(($(Get-Date) - $attemptStartTime).TotalSeconds, 2)
            Write-Warning "Package download failed in $attemptSeconds seconds"
            Write-Log -message ('{0} :: Package download failed in {1} seconds - {2:o}' -f $($MyInvocation.MyCommand.Name), $attemptSeconds, (Get-Date).ToUniversalTime()) -severity 'DEBUG'

            Write-Warning $_.Exception.Message

            if ($_.Exception.InnerException.Response.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) {
                Write-Warning "Request returned 404 Not Found. Aborting download."
                Write-Log -message ('{0} :: Request returned 404 Not Found. Aborting download. - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'
                $retries = 0
            }
        }

        if ($retries -eq 0) {
            $totalSeconds = [math]::Round(($(Get-Date) - $downloadStartTime).TotalSeconds, 2)
            throw "Package download failed after $totalSeconds seconds"
        }

        Write-Warning "Waiting $interval seconds before retrying (retries left: $retries)..."
        Write-Log -message ('{0} :: Waiting {1} seconds before retrying (retries left: {2})... - {3:o}' -f $($MyInvocation.MyCommand.Name), $interval, $retries, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
        Start-Sleep -Seconds $interval
    }

    return $Path
}

function Get-WinDisplayVersion {
    [CmdletBinding()]
    param (
        
    )
    
    return (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion
}

function Set-SSH {
    [CmdletBinding()]
    param (
        [Switch]
        $DownloadKeys
    )

    ## OpenSSH
    $sshdService = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($null -eq $sshdService) {
        Write-Log -message ('{0} :: Enabling OpenSSH.' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'
        switch (Get-WinDisplayVersion) {
            "24H2" {
                ## running this manually on 24h2 didn't need the trailing ~~~~0.0.1.0
                Add-WindowsCapability -Online -Name OpenSSH.Server
                ## When adding the open.ssh server capability, it doesn't start the service
                $destinationDirectory = "C:\users\administrator\.ssh"
                ## This is the path where the authorized_keys file will be saved
                $authorized_keys = Join-Path $destinationDirectory -ChildPath "authorized_keys"
                ## Create the hidden ssh directory
                New-Item -ItemType Directory -Path $destinationDirectory -Force
                Invoke-DownloadWithRetry "https://raw.githubusercontent.com/mozilla-platform-ops/worker-images/refs/heads/main/provisioners/windows/MDC1Windows/ssh/authorized_keys" -Path $authorized_keys
                Invoke-DownloadWithRetry "https://raw.githubusercontent.com/mozilla-platform-ops/worker-images/refs/heads/main/provisioners/windows/MDC1Windows/ssh/sshd_config" -Path "C:\programdata\ssh\sshd_config"
                $sshdService = Get-Service -Name sshd -ErrorAction SilentlyContinue
                if ($sshdService.status -ne "Running") {
                    Start-Service sshd
                    Set-Service -Name sshd -StartupType Automatic
                }
                ## Is sshdservice set to autmatically start?
                if ((Get-Service -Name sshd -ErrorAction SilentlyContinue).StartType -ne "Automatic") {
                    Set-Service -Name sshd -StartupType Automatic
                }
                $sshfw = @{
                    Name        = "AllowSSH"
                    DisplayName = "Allow SSH"
                    Description = "Allow SSH traffic on port 22"
                    Profile     = "Any"
                    Direction   = "Inbound"
                    Action      = "Allow"
                    Protocol    = "TCP"
                    LocalPort   = 22
                }
                New-NetFirewallRule @sshfw
            }
            default {
                $sshCapability = Get-WindowsCapability -Online | Where-Object { $_.Name -match "OpenSSH"}
                foreach ($ssh in $sshCapability) {
                    if ($ssh.State -eq "Present") {
                        Write-Log -message ('{0} :: Uninstalling {1}.' -f $($MyInvocation.MyCommand.Name),$ssh.name) -severity 'DEBUG'
                        Remove-WindowsCapability -Online -Name $ssh.name
                    }
                }
                Write-Log -message ('{0} :: Enabling OpenSSH.' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'
                $destinationDirectory = "C:\users\administrator\.ssh"
                $authorized_keys = $destinationDirectory + "authorized_keys"
                New-Item -ItemType Directory -Path $destinationDirectory -Force
                ## Now let's install it
                $win32_openssh = Invoke-DownloadWithRetry "https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.8.3.0p2-Preview/OpenSSH-Win64-v9.8.3.0.msi"
                ## Install the server component
                $install = Start-Process -FilePath msiexec.exe -ArgumentList "/i $win32_openssh /quiet /norestart ADDLOCAL=Server" -Wait -PassThru -NoNewWindow
                Write-host "win32_openssh install exit code: $($install.ExitCode)"
                Invoke-DownloadWithRetry "https://raw.githubusercontent.com/mozilla-platform-ops/worker-images/refs/heads/main/provisioners/windows/MDC1Windows/ssh/authorized_keys" -Path $authorized_keys
                Invoke-DownloadWithRetry "https://raw.githubusercontent.com/mozilla-platform-ops/worker-images/refs/heads/main/provisioners/windows/MDC1Windows/ssh/sshd_config" -Path "C:\programdata\ssh\sshd_config"
                $sshdService = Get-Service -Name ssh* -ErrorAction SilentlyContinue
                Write-host "sshdService status: $($sshdService.status)"
                ## Refresh env variable for ssh to work
                [Environment]::SetEnvironmentVariable("Path", [Environment]::GetEnvironmentVariable("Path",[System.EnvironmentVariableTarget]::Machine) + ';' + ${Env:ProgramFiles} + '\OpenSSH', [System.EnvironmentVariableTarget]::Machine)
                $sshfw = @{
                    Name        = "AllowSSH"
                    DisplayName = "Allow SSH"
                    Description = "Allow SSH traffic on port 22"
                    Profile     = "Any"
                    Direction   = "Inbound"
                    Action      = "Allow"
                    Protocol    = "TCP"
                    LocalPort   = 22
                }
                New-NetFirewallRule @sshfw
            }
        }
    }
    else {
        Write-Log -message ('{0} :: SSHd is running.' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'
        if ($sshdService.Status -ne 'Running') {
            Start-Service sshd
            Set-Service -Name sshd -StartupType Automatic
        }
        else {
            Write-Log -message ('{0} :: SSHD service is already running.' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'
        }
    }
}

function Set-WinRM {
    [CmdletBinding()]
    param (
        
    )
    ## WinRM
    Write-Log -message ('{0} :: Enabling WinRM.' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'
    $hardware = Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object -Property Manufacturer, Model
    $model = $hardware.Model
    switch ($model) {
        "ProLiant m710x Server Cartridge" {
            Set-NetConnectionProfile -NetworkCategory "Private"
        }
        Default {
            $adapter = Get-NetAdapter | Where-Object { $psitem.name -match "Ethernet" }
            $network_category = Get-NetConnectionProfile -InterfaceAlias $adapter.Name
            ## WinRM only works on the the active network interface if it is set to private
            if ($network_category.NetworkCategory -ne "Private") {
                Set-NetConnectionProfile -InterfaceAlias $adapter.name -NetworkCategory "Private"
            }
        }
    }
    Enable-PSRemoting -Force
}

function Install-Choco {
    [CmdletBinding()]
    param (
        
    )
    
    ## Install chocolatey here
    Set-ExecutionPolicy Unrestricted -Force -ErrorAction SilentlyContinue
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    
    if (-Not (Test-Path "C:\ProgramData\Chocolatey\bin\choco.exe")) {
        Set-PXE
    }
}

function Set-PXEWin10 {
    param ()
    begin {
        Write-Log -message ('{0} :: begin - {1:o}' -f $MyInvocation.MyCommand.Name, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    }
    process {
        $tempPath = "C:\\temp\\"
        New-Item -ItemType Directory -Force -Path $tempPath -ErrorAction SilentlyContinue

        bcdedit /enum firmware > "$tempPath\\firmware.txt"

        $fwBootMgr = Select-String -Path "$tempPath\\firmware.txt" -Pattern "{fwbootmgr}"
        if (!$fwBootMgr){
            Write-Log -message  ('{0} :: Device is configured for Legacy Boot. Exiting!' -f $MyInvocation.MyCommand.Name) -severity 'DEBUG'
            Exit 999
        }
        Try {
            $pxeGUID = (( Get-Content $tempPath\\firmware.txt | Select-String "IPV4|EFI Network" -Context 1 -ErrorAction Stop ).context.precontext)[0]

            $pxeGUID = '{' + $pxeGUID.split('{')[1]

            bcdedit /set "{fwbootmgr}" bootsequence "$pxeGUID"

            Write-Log -message  ('{0} :: Device will PXE boot. Restarting' -f $MyInvocation.MyCommand.Name) -severity 'DEBUG'
            Restart-Computer -Force
        }
        Catch {
            Write-Log -message  ('{0} :: Unable to set next boot to PXE. Exiting!' -f $MyInvocation.MyCommand.Name) -severity 'DEBUG'
            Exit 888
        }
    }
    end {
        Write-Log -message ('{0} :: end - {1:o}' -f $MyInvocation.MyCommand.Name, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    }
}

## Check until the machine is online
Test-ConnectionUntilOnline

## Setup WinRM just in case the machine fails so we have credentials to use
Set-WinRM

## Once we have internet connection, setup ssh and import the keys
Set-SSH

## Install chocolatey
## Commented out for Troubleshooting
Install-Choco

$local_bootstrap = "C:\bootstrap\bootstrap.ps1"

Invoke-DownloadWithRetry "https://raw.githubusercontent.com/mozilla-platform-ops/worker-images/main/provisioners/windows/MDC1Windows/bootstrap.ps1" -Path $local_bootstrap

if (-Not (Test-Path -Path $local_bootstrap)) {
    switch (Get-WinDisplayVersion) {
        "24H2" {
            Set-PXE
        }
        default {
            Set-PXEWin10
        }
    }
}

D:\applications\psexec.exe -i -s -d -accepteula powershell.exe -ExecutionPolicy Bypass -file $local_bootstrap -worker_pool_id "WorkerPoolId" -role "1Role"  -src_Organisation "SRCOrganisation" -src_Repository "SRCRepository" -src_Branch "SRCBranch" -hash "1HASH" -secret_date "1secret_date" -puppet_version "1puppet_version"
