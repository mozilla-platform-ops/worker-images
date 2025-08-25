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
        'DEBUG' { $entryType = 'SuccessAudit'; $eventId = 2 }
        'WARN'  { $entryType = 'Warning';      $eventId = 3 }
        'ERROR' { $entryType = 'Error';        $eventId = 4 }
        default { $entryType = 'Information';  $eventId = 1 }
    }
    Write-EventLog -LogName $logName -Source $source -EntryType $entryType -Category 0 -EventID $eventId -Message $message
    if ([Environment]::UserInteractive) {
        $fc = @{ 'Information'='White'; 'Error'='Red'; 'Warning'='DarkYellow'; 'SuccessAudit'='DarkGray' }[$entryType]
        Write-Host -Object $message -ForegroundColor $fc
    }
}

function Set-PXE {
    Import-Module Microsoft.Windows.Bcd.Cmdlets
    $data = (Get-BcdStore).entries | ForEach-Object {
        $d = ($_.Elements | Where-Object { $_.Name -eq "Description" }).value
        if ($d -match "IPv4") { $PSItem }
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
    while ($elapsedTime -lt $TotalTime) {
        if (Test-Connection -ComputerName $Hostname -Count 1 -Quiet) {
            Write-Log -message ('{0} :: {1} is online! Continuing.' -f $($MyInvocation.MyCommand.Name), $ENV:COMPUTERNAME) -severity 'DEBUG'
            return
        } else {
            Write-Log -message ('{0} :: {1} is not online, checking again in {2}' -f $($MyInvocation.MyCommand.Name), $ENV:COMPUTERNAME, $Interval) -severity 'DEBUG'
            Start-Sleep -Seconds $Interval
            $elapsedTime += $Interval
        }
    }
    Write-Log -message ('{0} :: {1} did not come online within {2} seconds' -f $($MyInvocation.MyCommand.Name), $ENV:COMPUTERNAME, $TotalTime) -severity 'DEBUG'
    throw "Connection timeout."
}

function Invoke-DownloadWithRetry {
    Param(
        [Parameter(Mandatory)] [string] $Url,
        [Alias("Destination")] [string] $Path
    )
    if (-not $Path) {
        $invalidChars = [IO.Path]::GetInvalidFileNameChars() -join ''
        $re = "[{0}]" -f [RegEx]::Escape($invalidChars)
        $fileName = [IO.Path]::GetFileName($Url) -replace $re
        if ([String]::IsNullOrEmpty($fileName)) { $fileName = [System.IO.Path]::GetRandomFileName() }
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
        } catch {
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

function Get-WinDisplayVersion { (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion }

function Set-SSH {
    [CmdletBinding()]
    param([Switch]$DownloadKeys)
    $sshdService = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($null -eq $sshdService) {
        Write-Log -message ('{0} :: Enabling OpenSSH.' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'
        $sshCapability = Get-WindowsCapability -Online | Where-Object { $_.Name -match "OpenSSH" }
        foreach ($ssh in $sshCapability) {
            if ($ssh.State -eq "Present") {
                Write-Log -message ('{0} :: Uninstalling {1}.' -f $($MyInvocation.MyCommand.Name), $ssh.name) -severity 'DEBUG'
                Remove-WindowsCapability -Online -Name $ssh.name
            }
        }
        Write-Log -message ('{0} :: Enabling OpenSSH.' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'
        $destinationDirectory = "C:\users\administrator\.ssh"
        $authorized_keys = $destinationDirectory + "\authorized_keys"
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        $win32_openssh = Invoke-DownloadWithRetry "https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.8.3.0p2-Preview/OpenSSH-Win64-v9.8.3.0.msi"
        $install = Start-Process -FilePath msiexec.exe -ArgumentList "/i $win32_openssh /quiet /norestart ADDLOCAL=Server" -Wait -PassThru -NoNewWindow
        Write-Host "win32_openssh install exit code: $($install.ExitCode)"
        Invoke-DownloadWithRetry "https://raw.githubusercontent.com/mozilla-platform-ops/worker-images/refs/heads/main/provisioners/windows/MDC1Windows/ssh/authorized_keys" -Path $authorized_keys
        Invoke-DownloadWithRetry "https://raw.githubusercontent.com/mozilla-platform-ops/worker-images/refs/heads/main/provisioners/windows/MDC1Windows/ssh/sshd_config" -Path "C:\programdata\ssh\sshd_config"
        $sshdService = Get-Service -Name ssh* -ErrorAction SilentlyContinue
        foreach ($s in $sshdService) {
            Write-Host "sshdService status: $($s.status)"
            Write-Log -message ('{0} :: sshdService status: {1}' -f $($MyInvocation.MyCommand.Name), $s.status) -severity 'DEBUG'
        }
        [Environment]::SetEnvironmentVariable("Path", [Environment]::GetEnvironmentVariable("Path", [System.EnvironmentVariableTarget]::Machine) + ';' + ${Env:ProgramFiles} + '\OpenSSH', [System.EnvironmentVariableTarget]::Machine)
        $sshfw = @{
            Name="AllowSSH"; DisplayName="Allow SSH"; Description="Allow SSH traffic on port 22"
            Profile="Any"; Direction="Inbound"; Action="Allow"; Protocol="TCP"; LocalPort=22
        }
        New-NetFirewallRule @sshfw | Out-Null
    } else {
        Write-Log -message ('{0} :: SSHd is present.' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'
        if ($sshdService.Status -ne 'Running') {
            Start-Service sshd
            Set-Service -Name sshd -StartupType Automatic
        } else {
            Write-Log -message ('{0} :: SSHD service is already running.' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'
        }
    }
}

function Set-WinRM {
    [CmdletBinding()]
    param (
        [int]$Retries = 2,
        [int]$DelaySeconds = 10
    )

    Write-Log -message ('{0} :: Preparing to enable WinRM (retries={1}, delay={2}s)' -f $($MyInvocation.MyCommand.Name), $Retries, $DelaySeconds) -severity 'DEBUG'

    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            Write-Log -message ('{0} :: Attempt {1}/{2}' -f $($MyInvocation.MyCommand.Name), $attempt, $Retries) -severity 'DEBUG'

            # Prefer the NIC with the default route
            $defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                            Sort-Object -Property RouteMetric, IfIndex | Select-Object -First 1

            $activeAdapter = $null
            if ($null -ne $defaultRoute) {
                $activeAdapter = Get-NetAdapter -IfIndex $defaultRoute.IfIndex -ErrorAction SilentlyContinue
            }
            if ($null -eq $activeAdapter) {
                $activeAdapter = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } |
                                 Sort-Object -Property IfIndex | Select-Object -First 1
            }

            if ($null -ne $activeAdapter) {
                $netProfile = Get-NetConnectionProfile -InterfaceIndex $activeAdapter.IfIndex -ErrorAction SilentlyContinue
                if ($null -eq $netProfile -or $netProfile.NetworkCategory -ne 'Private') {
                    Write-Log -message ('{0} :: Setting network category on {1} to Private (was: {2})' -f $($MyInvocation.MyCommand.Name), $activeAdapter.Name, ($netProfile.NetworkCategory | ForEach-Object { $_ })) -severity 'DEBUG'
                    try {
                        Set-NetConnectionProfile -InterfaceIndex $activeAdapter.IfIndex -NetworkCategory Private -ErrorAction Stop
                    } catch {
                        Write-Log -message ('{0} :: WARN: Failed to set Private on {1}: {2}' -f $($MyInvocation.MyCommand.Name), $activeAdapter.Name, $_.Exception.Message) -severity 'WARN'
                    }
                }
            } else {
                Write-Log -message ('{0} :: WARN: Could not determine an active adapter; continuing' -f $($MyInvocation.MyCommand.Name)) -severity 'WARN'
            }

            # Ensure WinRM service
            Set-Service -Name WinRM -StartupType Automatic -ErrorAction SilentlyContinue
            $svc = Get-Service -Name WinRM -ErrorAction SilentlyContinue
            if ($null -eq $svc -or $svc.Status -ne 'Running') {
                Start-Service -Name WinRM -ErrorAction SilentlyContinue
            }

            # Configure remoting + listeners (idempotent)
            Write-Log -message ('{0} :: Running Enable-PSRemoting -Force -SkipNetworkProfileCheck' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'
            Enable-PSRemoting -Force -SkipNetworkProfileCheck

            # Firewall rule (idempotent)
            if (-not (Get-NetFirewallRule -DisplayName 'WinRM HTTP-In' -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -DisplayName 'WinRM HTTP-In' -Name 'WinRM-HTTP-In' -Profile Domain,Private,Public `
                    -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5985 | Out-Null
            }

            # Validate listener + port
            $hasListener = $false
            try {
                $listeners = Get-ChildItem WSMan:\localhost\Listener -ErrorAction Stop
                $hasListener = ($listeners | Where-Object { $_.Keys['Transport'] -eq 'HTTP' }).Count -ge 1
            } catch { $hasListener = $false }

            $portOk = $false
            try { $portOk = [bool](Test-NetConnection -ComputerName 'localhost' -Port 5985 -InformationLevel Quiet) } catch { $portOk = $false }

            $svc = Get-Service -Name WinRM -ErrorAction SilentlyContinue
            $ok = ($svc -and $svc.Status -eq 'Running' -and $hasListener -and $portOk)
            Write-Log -message ('{0} :: Validation -> Service={1}; Listener={2}; Port5985={3}' -f $($MyInvocation.MyCommand.Name), ($svc.Status | ForEach-Object { $_ }), $hasListener, $portOk) -severity 'DEBUG'

            if ($ok) {
                Write-Log -message ('{0} :: WinRM is READY' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'
                return $true
            }
            throw "Validation failed (Service/Listener/Port not ready)."
        }
        catch {
            Write-Log -message ('{0} :: Attempt {1} failed: {2}' -f $($MyInvocation.MyCommand.Name), $attempt, $_.Exception.Message) -severity 'WARN'
            if ($attempt -lt $Retries) {
                Write-Log -message ('{0} :: Sleeping {1}s before retry' -f $($MyInvocation.MyCommand.Name), $DelaySeconds) -severity 'DEBUG'
                Start-Sleep -Seconds $DelaySeconds
            }
        }
    }

    Write-Log -message ('{0} :: WinRM could not be enabled after {1} attempts (continuing anyway)' -f $($MyInvocation.MyCommand.Name), $Retries) -severity 'WARN'
    return $false
}

function Install-Choco {
    if (-not $env:TEMP) { $env:TEMP = Join-Path $env:SystemDrive -ChildPath 'temp' }
    $chocoTempDir = Join-Path $env:TEMP -ChildPath "chocolatey"
    $tempDir = Join-Path $chocoTempDir -ChildPath "chocoInstall"
    if (-not (Test-Path $tempDir -PathType Container)) { $null = New-Item -Path $tempDir -ItemType Directory }

    $file = Join-Path $tempDir "chocolatey.zip"
    $ChocolateyDownloadUrl = "https://ronin-puppet-package-repo.s3.us-west-2.amazonaws.com/Windows/chocolatey.zip"
    Write-Host "Getting Chocolatey from $ChocolateyDownloadUrl."
    Invoke-DownloadWithRetry -Url $ChocolateyDownloadUrl -Path $file

    Write-Host "Extracting $file to $tempDir"
    Expand-Archive -Path $file -DestinationPath $tempDir -Force

    Write-Host "Installing Chocolatey on the local machine"
    $toolsFolder = Join-Path $tempDir -ChildPath "tools"
    $chocoInstallPS1 = Join-Path $toolsFolder -ChildPath "chocolateyInstall.ps1"
    & $chocoInstallPS1

    Write-Host 'Ensuring Chocolatey commands are on the path'
    $chocoInstallVariableName = "ChocolateyInstall"
    $chocoPath = [Environment]::GetEnvironmentVariable($chocoInstallVariableName)
    if (-not $chocoPath) { $chocoPath = "$env:ALLUSERSPROFILE\Chocolatey" }
    if (-not (Test-Path ($chocoPath))) { $chocoPath = "$env:PROGRAMDATA\chocolatey" }
    $chocoExePath = Join-Path $chocoPath -ChildPath 'bin'
    if ($env:Path -notlike "*$chocoExePath*") {
        $env:Path = [Environment]::GetEnvironmentVariable('Path', [System.EnvironmentVariableTarget]::Machine);
    }

    Write-Host 'Ensuring chocolatey.nupkg is in the lib folder'
    $chocoPkgDir = Join-Path $chocoPath -ChildPath 'lib\chocolatey'
    $nupkg = Join-Path $chocoPkgDir -ChildPath 'chocolatey.nupkg'
    if (-not (Test-Path $chocoPkgDir -PathType Container)) { $null = New-Item -ItemType Directory -Path $chocoPkgDir }
    Copy-Item -Path $file -Destination $nupkg -Force -ErrorAction SilentlyContinue

    if (-Not (Test-Path "C:\ProgramData\Chocolatey\bin\choco.exe")) {
        Write-Host "Chocolatey installation failed. Exiting."
        pause
    }
}

function Set-PXEWin10 {
    begin { Write-Log -message ('{0} :: begin - {1:o}' -f $MyInvocation.MyCommand.Name, (Get-Date).ToUniversalTime()) -severity 'DEBUG' }
    process {
        $tempPath = "C:\temp\"
        New-Item -ItemType Directory -Force -Path $tempPath -ErrorAction SilentlyContinue | Out-Null
        bcdedit /enum firmware > "$tempPath\firmware.txt"
        $fwBootMgr = Select-String -Path "$tempPath\firmware.txt" -Pattern "{fwbootmgr}"
        if (!$fwBootMgr) {
            Write-Log -message ('{0} :: Device is configured for Legacy Boot. Exiting!' -f $MyInvocation.MyCommand.Name) -severity 'DEBUG'
            Exit 999
        }
        Try {
            $pxeGUID = ((Get-Content "$tempPath\firmware.txt" | Select-String "IPV4|EFI Network" -Context 1 -ErrorAction Stop).context.precontext)[0]
            $pxeGUID = '{' + $pxeGUID.split('{')[1]
            bcdedit /set "{fwbootmgr}" bootsequence "$pxeGUID"
            Write-Log -message ('{0} :: Device will PXE boot. Restarting' -f $MyInvocation.MyCommand.Name) -severity 'DEBUG'
            Restart-Computer -Force
        } Catch {
            Write-Log -message ('{0} :: Unable to set next boot to PXE. Exiting!' -f $MyInvocation.MyCommand.Name) -severity 'DEBUG'
            Exit 888
        }
    }
    end { Write-Log -message ('{0} :: end - {1:o}' -f $MyInvocation.MyCommand.Name, (Get-Date).ToUniversalTime()) -severity 'DEBUG' }
}

function Invoke-DownloadWithRetryGithub {
    Param(
        [Parameter(Mandatory)] [string] $Url,
        [Alias("Destination")] [string] $Path,
        [string] $PAT
    )
    if (-not $Path) {
        $invalidChars = [IO.Path]::GetInvalidFileNameChars() -join ''
        $re = "[{0}]" -f [RegEx]::Escape($invalidChars)
        $fileName = [IO.Path]::GetFileName($Url) -replace $re
        if ([String]::IsNullOrEmpty($fileName)) { $fileName = [System.IO.Path]::GetRandomFileName() }
        $Path = Join-Path -Path "${env:Temp}" -ChildPath $fileName
    }
    Write-Host "Downloading package from $Url to $Path..."
    $interval = 30
    $downloadStartTime = Get-Date
    for ($retries = 20; $retries -gt 0; $retries--) {
        try {
            $attemptStartTime = Get-Date
            $Headers = @{
                Accept                 = "application/vnd.github+json"
                Authorization          = "Bearer $($PAT)"
                "X-GitHub-Api-Version" = "2022-11-28"
            }
            $response = Invoke-WebRequest -Uri $Url -Headers $Headers -OutFile $Path
            $attemptSeconds = [math]::Round(($(Get-Date) - $attemptStartTime).TotalSeconds, 2)
            Write-Host "Package downloaded in $attemptSeconds seconds"
            Write-Host "Status: $($response.statuscode)"
            break
        } catch {
            $attemptSeconds = [math]::Round(($(Get-Date) - $attemptStartTime).TotalSeconds, 2)
            Write-Warning "Package download failed in $attemptSeconds seconds"
            Write-Host "Status: $($response.statuscode)"
            Write-Warning $_.Exception.Message
            if ($_.Exception.InnerException.Response.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) {
                Write-Warning "Request returned 404 Not Found. Aborting download."
                $retries = 0
            }
        }
        if ($retries -eq 0) {
            $totalSeconds = [math]::Round(($(Get-Date) - $downloadStartTime).TotalSeconds, 2)
            throw "Package download failed after $totalSeconds seconds"
        }
        Write-Warning "Waiting $interval seconds before retrying (retries left: $retries)..."
        Start-Sleep -Seconds $interval
    }
    return $Path
}

# ===== Execution Flow =====

# Wait until internet works
Test-ConnectionUntilOnline

# Enable SSH and import keys
Set-SSH

# Enable WinRM (non-fatal, retry twice)
$winrmOk = Set-WinRM -Retries 2 -DelaySeconds 10
if (-not $winrmOk) {
    Write-Log -message 'get-bootstrap :: WinRM setup did not succeed after retries; continuing without it.' -severity 'WARN'
}

# Install Chocolatey
Install-Choco

# Fetch bootstrap.ps1
$local_bootstrap = "C:\bootstrap\bootstrap.ps1"
if (-Not (Test-Path "D:\Secrets\pat.txt")) {
    $splat = @{ Url = "https://raw.githubusercontent.com/mozilla-platform-ops/worker-images/main/provisioners/windows/MDC1Windows/bootstrap.ps1"; Path = $local_bootstrap }
    Invoke-DownloadWithRetry @splat
} else {
    #$splat = @{ Url = "https://raw.githubusercontent.com/mozilla-platform-ops/worker-images/main/provisioners/windows/MDC1Windows/bootstrap.ps1"; Path = $local_bootstrap; PAT = Get-Content "D:\Secrets\pat.txt" }
    ## JUST for TESTING CHANGE BEFORE PR
    $splat = @{ Url = "https://raw.githubusercontent.com/mozilla-platform-ops/worker-images/refs/heads/RELOPS-1660/provisioners/windows/MDC1Windows/bootstrap.ps1"; Path = $local_bootstrap; PAT = Get-Content "D:\Secrets\pat.txt" }
    Invoke-DownloadWithRetryGithub @splat
}

# If we still don't have bootstrap, PXE fallback
if (-Not (Test-Path -Path $local_bootstrap)) {
    switch (Get-WinDisplayVersion) {
        "24H2" { Set-PXE }
        default { Set-PXEWin10 }
    }
}

# Run bootstrap with PsExec
D:\applications\psexec.exe -i -s -d -accepteula powershell.exe -ExecutionPolicy Bypass -file $local_bootstrap `
    -worker_pool_id "WorkerPoolId" `
    -role "1Role" `
    -src_Organisation "SRCOrganisation" `
    -src_Repository "SRCRepository" `
    -src_Branch "SRCBranch" `
    -hash "1HASH" `
    -secret_date "1secret_date" `
    -puppet_version "1puppet_version" `
    -git_version "1git_version" `
    -openvox_version "1openvox_version"
