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
        Write-Log -message ('{0} :: Waiting {1} seconds before retrying (retries left: {2}})... - {3:o}' -f $($MyInvocation.MyCommand.Name), $interval, $retries, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
        Start-Sleep -Seconds $interval
    }

    return $Path
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
        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
        Invoke-DownloadWithRetry -Url https://raw.githubusercontent.com/SRCOrganisation/SRCRepository/SRCBranch/provisioners/windows/ImageProvisioner/authorized_keys -Path $AuthorizedKeys
        Invoke-DownloadWithRetry -Url https://raw.githubusercontent.com/SRCOrganisation/SRCRepository/SRCBranch/provisioners/windows/ImageProvisioner/bootstrap.ps1 -Path $local_bootstrap
        Start-Service sshd
        Set-Service -Name sshd -StartupType Automatic
        New-NetFirewallRule -Name "AllowSSH" -DisplayName "Allow SSH" -Description "Allow SSH traffic on port 22" -Profile Any -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22
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
    $adapter = Get-NetAdapter | Where-Object { $psitem.name -match "Ethernet" }
    $network_category = Get-NetConnectionProfile -InterfaceAlias $adapter.Name
    ## WinRM only works on the the active network interface if it is set to private
    if ($network_category.NetworkCategory -ne "Private") {
        Set-NetConnectionProfile -InterfaceAlias $adapter.name -NetworkCategory "Private"
        Enable-PSRemoting -Force
    }
}

$AuthorizedKeys = "C:\users\administrator\authorized_keys"
$local_bootstrap = "C:\bootstrap\bootstrap.ps1"

Test-ConnectionUntilOnline

## Setup logging much earlier

## Set up ssh early on to ensure access if bootstrap fails.
Set-WinRM
Set-SSH -DownloadKeys $true

powershell -file $local_bootstrap -worker_pool_id WorkerPoolId -role 1Role  -src_Organisation SRCOrganisation -src_Repository SRCRepository -src_Branch SRCBranch