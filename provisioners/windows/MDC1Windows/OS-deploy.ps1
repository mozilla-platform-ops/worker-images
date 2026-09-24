param(
    [string]$deployuser,
    [string]$deploymentaccess,
    [string]$branch = "main",
    [string]$worker_images_revision,
    [switch]$devlopment_script = $false

)
function Deploy-OS-Dev {
    param (
        [string]$branch,
        [string]$Password
    )
    $local_dir = "X:\working"
    Mount-ZDrive
    try {
        $pat = (Get-Content 'Z:\secrets\pat.txt' -Raw -ErrorAction Stop).Trim()
        $revision = Resolve-WorkerImagesRevision -Ref $branch -PAT $pat
    }
    finally {
        Remove-Variable pat -ErrorAction SilentlyContinue
        Remove-PSDrive -Name Z -Scope Global -Force -ErrorAction SilentlyContinue
    }
    $source = "https://raw.githubusercontent.com/mozilla-platform-ops/worker-images/${revision}/provisioners/windows/MDC1Windows"
    $script = "OS-deploy.ps1"
    $deploy_script = "$local_dir\$script"

    Set-ExecutionPolicy Bypass -Scope Process -Force

    Write-Host "Beginning OS deployment."

    # Ensure the local directory exists
    New-Item -ItemType Directory -Path $local_dir -Force | Out-Null

    $maxRetries = 20  # 20 retries * 30 seconds each = 10 minutes
    $retryInterval = 30  # seconds

    # Remove existing files if present
    if (Test-Path -Path $deploy_script) {
        Remove-Item $deploy_script -Force
    }

    Write-Host "DEV Downloading OS deploy script."

    for ($retryCount = 1; $retryCount -le $maxRetries; $retryCount++) {
        try {
            Invoke-WebRequest -Uri "$source/$script" -OutFile $deploy_script
            break  # Break out of the loop if download is successful
        }
        catch {
            Write-Host "Attempt ${retryCount}: An error occurred - $Error[0]"
            Write-Host "Retrying in $retryInterval seconds..."
            Start-Sleep -Seconds $retryInterval
        }
    }

    if ($retryCount -gt $maxRetries) {
        Write-Host "Download failed after $maxRetries attempts. Exiting function."
        return
    }

    Write-Host "Running DEV deployment script..."
    $branch = "$($pool.dev)"
    & $deploy_script -deployuser "deployment" -deploymentaccess $Password -devlopment_script -branch $branch -worker_images_revision $revision
}

function Get-DeploySendoff {
    param(
    )
    ## Sign-off line printed just before we hand the node over to Setup / reboot into the
    ## deployed OS. Cosmetic only - nothing parses this.
    $lines = @(
        'This is probably fine in every timeline.'
        'Please keep all limbs inside the deployment.'
        'Here be undocumented behavior.'
        'The wizard responsible has been notified.'
        'Success is now statistically possible.'
        'Do not feed the production environment.'
        'We have angered the dependency gods.'
        'Something ancient just returned exit code 1.'
        'The deployment must flow.'
        'Good luck. The machines are watching.'
        'The machine spirit is willing.'
    )
    return (Get-Random -InputObject $lines)
}

function Mount-ZDrive {
    param(
    )
    ## Mount the deployment share only for this PowerShell session. Keeping the password
    ## in PSCredential avoids exposing it in net.exe process arguments.
    $deploypw = ConvertTo-SecureString -String $deploymentaccess -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($deployuser, $deploypw)

    $maxRetries = 20
    $retryInterval = 30

    Write-Host "Mounting Deployment Share."
    for ($retryCount = 1; $retryCount -le $maxRetries; $retryCount++) {
        try {
            Remove-PSDrive -Name Z -Scope Global -Force -ErrorAction SilentlyContinue
            New-PSDrive -Name Z -PSProvider FileSystem -Root '\\mdt2022.ad.mozilla.com\deployments' `
                -Credential $credential -Scope Global -ErrorAction Stop | Out-Null
            break
        }
        catch {
            Write-Host Unable to mount Deployment Share
            Start-Sleep -Seconds $retryInterval
        }
    }
    if ($retryCount -gt $maxRetries) {
        Write-Host Failed to mount Deployment Share
        exit 99
    }
}

function Resolve-WorkerImagesRevision {
    param(
        [Parameter(Mandatory)][string] $Ref,
        [Parameter(Mandatory)][string] $PAT
    )

    $headers = @{
        Accept                 = 'application/vnd.github+json'
        Authorization          = "Bearer $PAT"
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'worker-images-mdc1-deploy'
    }
    $encodedRef = [uri]::EscapeDataString($Ref)
    $result = Invoke-RestMethod -Uri "https://api.github.com/repos/mozilla-platform-ops/worker-images/commits/$encodedRef" -Headers $headers
    $revision = [string]$result.sha
    if ($revision -notmatch '^[0-9a-fA-F]{40}$') {
        throw "GitHub returned an invalid worker-images revision for '$Ref'."
    }
    return $revision.ToLowerInvariant()
}

function Test-ProvisioningDriveAcl {
    param([System.Security.AccessControl.DirectorySecurity]$Acl)

    $admins = 'S-1-5-32-544'
    $allowedSids = @('S-1-5-18', $admins)
    $rules = @($Acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
    if ((-not $Acl.AreAccessRulesProtected) -or
        ($Acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -ne $admins) -or
        ($rules.Count -ne $allowedSids.Count)) {
        return $false
    }

    foreach ($sid in $allowedSids) {
        $rule = @($rules | Where-Object { $_.IdentityReference.Value -eq $sid })
        if (($rule.Count -ne 1) -or
            ($rule[0].AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) -or
            ($rule[0].FileSystemRights -ne [System.Security.AccessControl.FileSystemRights]::FullControl) -or
            ($rule[0].InheritanceFlags -ne ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit)) -or
            ($rule[0].PropagationFlags -ne [System.Security.AccessControl.PropagationFlags]::None) -or
            $rule[0].IsInherited) {
            return $false
        }
    }
    return $true
}

function Protect-ProvisioningDrive {
    param([switch]$Fresh)

    # Protected DACL: SYSTEM and built-in Administrators, inheritable full control.
    $acl = [System.Security.AccessControl.DirectorySecurity]::new()
    $acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
    $currentAcl = Get-Acl -LiteralPath 'D:\'

    if (Test-ProvisioningDriveAcl $currentAcl) {
        return
    }

    if (-not $Fresh) {
        # Existing children may carry attacker-controlled protected ACLs, so changing only
        # the root DACL is insufficient. Recreate this cache volume once during rollout.
        Write-Warning 'D: was not protected; formatting it before reusing provisioning content.'
        Format-Volume -DriveLetter D -FileSystem NTFS -Force -Confirm:$false -ErrorAction Stop | Out-Null
    }

    Set-Acl -LiteralPath 'D:\' -AclObject $acl

    $actualAcl = Get-Acl -LiteralPath 'D:\'
    if (-not (Test-ProvisioningDriveAcl $actualAcl)) {
        $actualOwner = $actualAcl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        throw "Failed to restrict D:\ to SYSTEM and Administrators. Owner=$actualOwner SDDL=$($actualAcl.Sddl)"
    }
}

function Update-PATSecret {
    <#
    .SYNOPSIS
        Re-copies pat.txt from the deployment share and returns the refreshed token.

    .DESCRIPTION
        raw.githubusercontent.com answers a request for a public file that carries an
        expired or malformed bearer token with 404, not 401. A stale pat.txt on the node
        is therefore indistinguishable from a genuinely missing file. This re-copies
        pat.txt from the deployment share using the same mount and copy logic used during
        the initial file sync, then returns the new token so the caller can retry.

    .OUTPUTS
        The refreshed PAT as a trimmed string, or $null if it could not be refreshed.
    #>

    Param
    (
        [string] $Source = $source_secrets_pat,
        [string] $Destination = $PATsecret_file
    )

    if ([string]::IsNullOrWhiteSpace($Source) -or [string]::IsNullOrWhiteSpace($Destination)) {
        Write-Warning "PAT source or destination path is not set. Cannot refresh PAT."
        return $null
    }

    try {
        Mount-ZDrive

        if (-Not (Test-Path $Source)) {
            Write-Warning "$Source not found on the Deployment Share. Cannot refresh PAT."
            return $null
        }

        $destination_dir = Split-Path -Path $Destination -Parent
        if (-Not (Test-Path $destination_dir)) {
            Write-Host "Creating $destination_dir"
            New-Item -ItemType Directory -Path $destination_dir -Force | Out-Null
        }

        Write-Host "Copying $Source to $Destination"
        Copy-Item -Path $Source -Destination $Destination -Force

        return ((Get-Content $Destination -Raw).Trim())
    }
    catch {
        Write-Warning "PAT refresh failed: $($_.Exception.Message)"
        return $null
    }
    finally {
        Write-Host "Disconecting Deployment Share."
        Remove-PSDrive -Name Z -Scope Global -Force -ErrorAction SilentlyContinue
    }
}
function Update-GetBoot {
    param(
        [Parameter(Mandatory)][string]$revision
    )
    $Get_Bootstrap = "D:\scripts\Get-Bootstrap.ps1"
    $Template_Get_Bootstrap = $local_scripts + "Template_Get-Bootstrap.ps1"

    ## Remove existing Get-Bootstrap.ps1 with latest values

    if (Test-Path $Get_Bootstrap) {
        Remove-Item $Get_Bootstrap -Force
    }
    if (Test-Path $Template_Get_Bootstrap) {
        Remove-Item $Template_Get_Bootstrap -Force
    }

    $bootstrapSplat = @{
        URI     = "https://raw.githubusercontent.com/mozilla-platform-ops/worker-images/$revision/provisioners/windows/MDC1Windows/Get-Bootstrap.ps1"
        OutFile = $Template_Get_Bootstrap
    }
    write-host checking
    write-host $revision
    write-host $pool.dev
    write-host "Invoke-WebRequest @bootstrapSplat"
    write-host $bootstrapSplat.URI

    if (-Not (Test-Path "D:\Secrets\pat.txt")) {
        $splat = @{
            Url  = $bootstrapSplat.URI
            Path = $bootstrapSplat.OutFile
        }

        Invoke-DownloadWithRetry @splat
    }
    else {
        $splat = @{
            Url  = $bootstrapSplat.URI
            Path = $bootstrapSplat.OutFile
            PAT  = Get-Content "D:\Secrets\pat.txt"
        }

        Invoke-DownloadWithRetryGithub @splat
    }

    $replacements = @(
        @{ OldString = "WorkerPoolId"; NewString = $WorkerPool },
        @{ OldString = "1Role"; NewString = $role },
        @{ OldString = "SRCOrganisation"; NewString = $src_Organisation },
        @{ OldString = "SRCRepository"; NewString = $src_Repository },
        @{ OldString = "ImageProvisioner"; NewString = "MDC1Windows" },
        @{ OldString = "SRCBranch"; NewString = $src_Branch },
        @{ OldString = "1HASH"; NewString = $hash },
        @{ OldString = "1secret_date"; NewString = $secret_date },
        @{ OldString = "1puppet_version"; NewString = $puppet_version }
        @{ OldString = "1openvox_version"; NewString = $openvox_version }
        @{ OldString = "1git_version"; NewString = $git_version }
        @{ OldString = "WIRevisionPlaceholder"; NewString = $revision }
    )
    $content = Get-Content -Path $Template_Get_Bootstrap
    foreach ($replacement in $replacements) {
        $content = $content -replace $replacement.OldString, $replacement.NewString
    }

    Set-Content -Path $Get_Bootstrap -Value $content
}

# Function to partition and format a single disk with both C and D
function PartitionAndFormat-SingleDisk {
    $availableSpace = Get-Disk | Where-Object { $_.OperationalStatus -eq 'Online' } | Measure-Object -Property Size -Sum
    Write-Host "No partitions found. Partitioning disk."

    $local_files_size = 21480
    $all_space = [math]::Floor($availableSpace.Sum / 1MB)
    $primary_size = ($all_space - $local_files_size)

    Write-Host "Avilable space $all_space MB"
    Write-Host "Primary partition size is $primary_size MB"
    Write-Host "Local Install Partition is $local_files_size MB"

    $diskPartScript = @"
        select disk 0
        clean
        convert gpt
        create partition efi size=100
        format fs=fat32 label=EFI
        assign letter=S
        create partition msr size=16
        create partition primary size=$primary_size
        format fs=ntfs quick
        assign letter=C
        create partition primary $local_files
        format fs=ntfs quick
        assign letter=D
        exit
"@

    $diskPartScript | Out-File -FilePath "$env:TEMP\diskpart_script.txt" -Encoding ASCII
    $diskPartScript | Out-File -FilePath "test.txt" -Encoding ASCII
    Start-Process "diskpart.exe" -ArgumentList "/s $env:TEMP\diskpart_script.txt" -Wait
}

function PartitionAndFormat-TwoDisks {
    param (
        [int]$DiskC, # Disk number for the larger disk
        [int]$DiskD  # Disk number for the smaller disk
    )

    # Get the sizes of all disks
    $diskSizes = Get-Disk | Where-Object { $_.OperationalStatus -eq 'Online' } | Select-Object Number, Size

    # Determine the main disk (largest storage) and secondary disk
    $mainDisk = $diskSizes | Sort-Object -Property Size -Descending | Select-Object -First 1
    $secondaryDisk = $diskSizes | Where-Object { $_.Number -ne $mainDisk.Number } | Select-Object -First 1

    $DiskC = $mainDisk.Number
    $DiskD = $secondaryDisk.Number

    Write-Host "Main Disk: Disk $DiskC with size $($mainDisk.Size / 1GB) GB"
    Write-Host "Secondary Disk: Disk $DiskD with size $($secondaryDisk.Size / 1GB) GB"

    # Define sizes for the EFI, MSR, and local files partitions
    $efiSize = 100  # EFI partition size in MB
    $msrSize = 16   # MSR partition size in MB
    $localFilesSize = 21480  # Local files partition size in MB

    # Calculate the primary partition size for the main disk (DiskC)
    $totalCSizeMB = [math]::Floor($mainDisk.Size / 1MB)
    $primaryPartitionSizeC = $totalCSizeMB - ($efiSize + $msrSize + $localFilesSize)

    Write-Host "Partitioning Main Disk (DiskC) with size $totalCSizeMB MB:" -ForegroundColor Green
    Write-Host "- EFI Partition: $efiSize MB"
    Write-Host "- MSR Partition: $msrSize MB"
    Write-Host "- Primary Partition (C): $primaryPartitionSizeC MB"
    Write-Host "- Local Install Partition: $localFilesSize MB"

    # Diskpart script for the main disk (DiskC)
    $diskPartScriptC = @"
select disk $DiskC
clean
convert gpt
create partition efi size=$efiSize
format fs=fat32 label=EFI quick
assign letter=S
create partition msr size=$msrSize
create partition primary size=$primaryPartitionSizeC
format fs=ntfs quick
assign letter=C
create partition primary size=$localFilesSize
format fs=ntfs quick
assign letter=E
exit
"@

    # Diskpart script for the secondary disk (DiskD)
    Write-Host "Partitioning Secondary Disk (DiskD) as a single partition:" -ForegroundColor Green

    $diskPartScriptD = @"
select disk $DiskD
clean
convert gpt
create partition primary
format fs=ntfs quick
assign letter=D
exit
"@

    # Save the Diskpart scripts
    $scriptPathC = "$env:TEMP\diskpart_script_c.txt"
    $diskPartScriptC | Out-File -FilePath $scriptPathC -Encoding ASCII
    $scriptPathD = "$env:TEMP\diskpart_script_d.txt"
    $diskPartScriptD | Out-File -FilePath $scriptPathD -Encoding ASCII

    # Run Diskpart for both disks
    Start-Process "diskpart.exe" -ArgumentList "/s $scriptPathC" -Wait
    Start-Process "diskpart.exe" -ArgumentList "/s $scriptPathD" -Wait

    Write-Host "Partitioning complete. Disk $DiskC has been partitioned as the primary drive with multiple partitions. Disk $DiskD is formatted as a single partition." -ForegroundColor Green
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
    #Write-Log -message ('{0} :: Downloading {1} to {2} - {3:o}' -f $($MyInvocation.MyCommand.Name), $url, $path, (Get-Date).ToUniversalTime()) -severity 'DEBUG'

    $interval = 30
    $downloadStartTime = Get-Date
    for ($retries = 20; $retries -gt 0; $retries--) {
    try {
        $attemptStartTime = Get-Date

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Path

        $attemptSeconds = [math]::Round(($(Get-Date) - $attemptStartTime).TotalSeconds, 2)
        Write-Host "Package downloaded in $attemptSeconds seconds"
        #Write-Log -message ('{0} :: Package downloaded in {1} seconds - {2:o}' -f $($MyInvocation.MyCommand.Name), $attemptSeconds, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
        break
    }
        catch {
            $attemptSeconds = [math]::Round(($(Get-Date) - $attemptStartTime).TotalSeconds, 2)
            Write-Warning "Package download failed in $attemptSeconds seconds"
            #Write-Log -message ('{0} :: Package download failed in {1} seconds - {2:o}' -f $($MyInvocation.MyCommand.Name), $attemptSeconds, (Get-Date).ToUniversalTime()) -severity 'DEBUG'

            Write-Warning $_.Exception.Message

            if ($_.Exception.InnerException.Response.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) {
                Write-Warning "Request returned 404 Not Found. Aborting download."
                #Write-Log -message ('{0} :: Request returned 404 Not Found. Aborting download. - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'
                $retries = 0
            }
        }

        if ($retries -eq 0) {
            $totalSeconds = [math]::Round(($(Get-Date) - $downloadStartTime).TotalSeconds, 2)
            throw "Package download failed after $totalSeconds seconds"
        }

        Write-Warning "Waiting $interval seconds before retrying (retries left: $retries)..."
        #Write-Log -message ('{0} :: Waiting {1} seconds before retrying (retries left: {2})... - {3:o}' -f $($MyInvocation.MyCommand.Name), $interval, $retries, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
        Start-Sleep -Seconds $interval
    }

    return $Path
}

function Invoke-DownloadWithRetryGithub {
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
        [string] $Path,
        [string] $PAT
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
    #Write-Log -message ('{0} :: Downloading {1} to {2} - {3:o}' -f $($MyInvocation.MyCommand.Name), $url, $path, (Get-Date).ToUniversalTime()) -severity 'DEBUG'

    $interval = 30
    $downloadStartTime = Get-Date
    $PATrefreshed = $false
    for ($retries = 20; $retries -gt 0; $retries--) {
        try {
            $attemptStartTime = Get-Date
            $webClient = New-Object System.Net.WebClient
            $webClient.Headers.Add("Accept", "application/vnd.github+json")
            $webClient.Headers.Add("Authorization", "Bearer $($PAT)")
            $webClient.Headers.Add("X-GitHub-Api-Version", "2022-11-28")
            $webClient.DownloadFile($Url, $Path)
            $attemptSeconds = [math]::Round(($(Get-Date) - $attemptStartTime).TotalSeconds, 2)
            Write-Host "Package downloaded in $attemptSeconds seconds"
            #Write-Log -message ('{0} :: Package downloaded in {1} seconds - {2:o}' -f $($MyInvocation.MyCommand.Name), $attemptSeconds, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
            break
        }
        catch {
            $attemptSeconds = [math]::Round(($(Get-Date) - $attemptStartTime).TotalSeconds, 2)
            Write-Warning "Package download failed in $attemptSeconds seconds"
            #Write-Log -message ('{0} :: Package download failed in {1} seconds - {2:o}' -f $($MyInvocation.MyCommand.Name), $attemptSeconds, (Get-Date).ToUniversalTime()) -severity 'DEBUG'

            Write-Warning $_.Exception.Message

            if ($_.Exception.InnerException.Response.StatusCode -eq [System.Net.HttpStatusCode]::NotFound) {
                ## A 404 here is usually an expired PAT rather than a missing file, because
                ## GitHub returns 404 instead of 401 for a bad bearer token. Refresh pat.txt
                ## from the Deployment Share once and retry before giving up on the file.
                if (-Not $PATrefreshed) {
                    $PATrefreshed = $true
                    Write-Warning "Request returned 404 Not Found. This is often an expired PAT. Refreshing PAT from the Deployment Share."
                    #Write-Log -message ('{0} :: Request returned 404 Not Found. Refreshing PAT from the Deployment Share. - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'

                    $refreshed_PAT = Update-PATSecret

                    if ([string]::IsNullOrWhiteSpace($refreshed_PAT)) {
                        Write-Warning "PAT could not be refreshed. Aborting download."
                        $retries = 0
                    }
                    elseif (($PAT -join '').Trim() -eq $refreshed_PAT) {
                        Write-Warning "Refreshed PAT matches the PAT that just failed. The PAT on the Deployment Share is stale and needs to be replaced. Aborting download."
                        $retries = 0
                    }
                    else {
                        Write-Host "PAT refreshed. Retrying download."
                        $PAT = $refreshed_PAT
                        continue
                    }
                }
                else {
                    Write-Warning "Request returned 404 Not Found after refreshing the PAT. Aborting download."
                    #Write-Log -message ('{0} :: Request returned 404 Not Found after refreshing the PAT. Aborting download. - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'
                    $retries = 0
                }
            }
        }

        if ($retries -eq 0) {
            $totalSeconds = [math]::Round(($(Get-Date) - $downloadStartTime).TotalSeconds, 2)
            throw "Package download failed after $totalSeconds seconds"
        }

        Write-Warning "Waiting $interval seconds before retrying (retries left: $retries)..."
        #Write-Log -message ('{0} :: Waiting {1} seconds before retrying (retries left: {2})... - {3:o}' -f $($MyInvocation.MyCommand.Name), $interval, $retries, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
        Start-Sleep -Seconds $interval
    }

    return $Path
}

## Get node name
Set-Location X:\working

Write-Host "Working from branch "$branch"."

$Ethernet = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object { $_.name -match "ethernet" }
try {
    $IPAddress = ($Ethernet.GetIPProperties().UnicastAddresses |
        Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and $_.Address.IPAddressToString -ne "127.0.0.1" } |
        Select-Object -ExpandProperty Address).IPAddressToString

    if (-not $IPAddress) {
        throw "No IP address found using .NET method."
    }
}
catch {
    $NetshOutput = netsh interface ip show addresses
    $IPAddress = ($NetshOutput -match "IP Address" | ForEach-Object {
            if ($_ -notmatch "127.0.0.1") {
                $_ -replace ".*?:\s*", ""
            }
        }).Trim()
}

if ($IPAddress) {
    Write-Host "IP Address: $IPAddress"
}
else {
    Write-Host "No IP Address could be determined." -ForegroundColor Red
}

$ResolvedName = ((Resolve-DnsName -Name $IPAddress -Server "10.48.75.120").NameHost)
write-host $ResolvedName

$index = $ResolvedName.IndexOf('.')
$shortname = $ResolvedName.Substring(0, $index)

write-host checking name

$DomainSuffix = $ResolvedName -replace '^[^.]*\.', ''

Write-Host "Host name set to be $ResolvedName"

## Get data
## Assumes files is in the same dir.
# Resolve the selected branch once, then use that immutable revision for the whole deploy.
# Read the GitHub token directly from the deployment share; do not trust a cached D: copy
# before Protect-ProvisioningDrive has run.
Mount-ZDrive
try {
    $workerImagesPAT = (Get-Content 'Z:\secrets\pat.txt' -Raw -ErrorAction Stop).Trim()
    if ($worker_images_revision) {
        if ($worker_images_revision -notmatch '^[0-9a-fA-F]{40}$') {
            throw 'OS-deploy received an invalid worker-images revision.'
        }
        $workerImagesRevision = $worker_images_revision.ToLowerInvariant()
    }
    else {
        $workerImagesRevision = Resolve-WorkerImagesRevision -Ref $branch -PAT $workerImagesPAT
    }
    Write-Host "Pinned worker-images '$branch' to $workerImagesRevision"
    Invoke-DownloadWithRetryGithub `
        -Url "https://raw.githubusercontent.com/mozilla-platform-ops/worker-images/$workerImagesRevision/provisioners/windows/MDC1Windows/pools.yml" `
        -Path 'pools.yml' -PAT $workerImagesPAT
}
finally {
    Remove-Variable workerImagesPAT -ErrorAction SilentlyContinue
    Remove-PSDrive -Name Z -Scope Global -Force -ErrorAction SilentlyContinue
}
$YAML = Convertfrom-Yaml (Get-Content "pools.yml" -raw)

foreach ($pool in $YAML.pools) {
    foreach ($node in $pool.nodes) {
        if ($node -match $shortname) {
            $neededImage = $pool.image
            $WorkerPool = $pool.name
            $role = $WorkerPool -replace "-", ""
            $src_Organisation = $pool.src_Organisation
            $src_Repository = $pool.src_Repository
            $src_Branch = $pool.src_Branch
            $hash = $pool.hash
            $secret_date = $pool.secret_date
            $puppet_version = $pool.puppet_version
            $openvox_version = $pool.openvox_version
            $git_version = $pool.git_version
            Write-Output "The associated image for $shortname is: $neededImage"
            if ($pool.dev -and (-not $devlopment_script)) {
                Write-Host "Dev mode is enabled."
                Deploy-OS-Dev -Password $deploymentaccess -branch $pool.dev
                exit
            }
            $found = $true
            break
        }
        if ($found) {
            break
        }
        else {
            $defaultPool = $YAML.pools | Where-Object { $_.name -eq "Default" }
            $neededImage = $defaultPool.image
            $WorkerPool = $pool.name
            $WorkerPool = $pool.name
            $role = $WorkerPool -replace "-", ""
            $src_Organisation = $pool.src_Organisation
            $src_Repository = $pool.src_Repository
            $src_Branch = $pool.src_Branch
            $secret_date = $pool.secret_date
            $openvox_version = "8.19.2"
            $git_version = "2.50.0"
            $puppet_version = "6.28.0"
        }
    }
}

Write-Host "Preparing local environment."
Set-Location X:\working
Import-Module "X:\Windows\System32\WindowsPowerShell\v1.0\Modules\DnsClient"
Import-Module "X:\Windows\System32\WindowsPowerShell\v1.0\Modules\powershell-yaml"

Write-Host "Detecting available disks..."
$disks = Get-Disk | Where-Object { $_.OperationalStatus -eq 'Online' }
$diskCount = (Get-Disk | Measure-Object).Count

$existingC = Get-Partition | Where-Object { $_.DriveLetter -eq 'C' }
$existingD = Get-Partition | Where-Object { $_.DriveLetter -eq 'D' }

if ($existingC -and $existingD) {
    Write-Host "Drives C and D are already labeled and configured. Skipping partitioning."
    $skipPartitioning = $true
}
else {
    Write-Host "Partitioning required. Drives are not properly configured."
    $skipPartitioning = $false
}

# Main logic for disk selection and formatting
if (!($skipPartitioning)) {
    if ($diskCount -eq 2) {
        # Sort disks by size and select larger as C and smaller as D
        $sortedDisks = $disks | Sort-Object -Property Size -Descending
        $diskC = $sortedDisks[1].Number
        $diskD = $sortedDisks[0].Number

        Write-Host "Two disks found. Setting up the larger disk as C and the smaller as D."
        PartitionAndFormat-TwoDisks -DiskC $diskC -DiskD $diskD
    }
    elseif ($diskCount -eq 1) {
        # Only one disk found, use it for both C and D
        $singleDisk = $disks[0].Number
        Write-Host "Only one disk found. Setting up C and D partitions on the same disk."
        PartitionAndFormat-SingleDisk -DiskNumber $singleDisk
    }
    else {
        Write-Host "No suitable disks found or more than two disks detected."
    }
}

# Pause before label check
Start-Sleep -Seconds 5

# Label verification and correction
if ($disks.Count -eq 2) {
    # Check labels on two disks
    $partC = Get-Partition | Where-Object { $_.DriveLetter -eq 'C' }
    $partD = Get-Partition | Where-Object { $_.DriveLetter -eq 'D' }

    if (-not $partC) {
        Write-Host "OS Disk incorrectly labeled. Relabeling to C."
        $diskCPartition = Get-Partition -DiskNumber $diskC -PartitionNumber 3
        Set-Partition -DiskNumber $diskCPartition.DiskNumber -PartitionNumber $diskCPartition.PartitionNumber -NewDriveLetter C
    }

    if (-not $partD) {
        Write-Host "Second disk incorrectly labeled. Relabeling to D."
        $diskDPartition = Get-Partition -DiskNumber $diskD -PartitionNumber 1
        Set-Partition -DiskNumber $diskDPartition.DiskNumber -PartitionNumber $diskDPartition.PartitionNumber -NewDriveLetter D
    }
}
elseif ($disks.Count -eq 1) {
    # Check labels on single disk
    $partitions = Get-Partition -DiskNumber $singleDisk

    $partC = $partitions | Where-Object { $_.PartitionNumber -eq 3 -and $_.DriveLetter -ne 'C' }
    $partD = $partitions | Where-Object { $_.PartitionNumber -eq 4 -and $_.DriveLetter -ne 'D' }

    if ($partC) {
        Write-Host "OS Disk incorrectly labeled. Relabeling partition to C."
        Set-Partition -DiskNumber $partC.DiskNumber -PartitionNumber $partC.PartitionNumber -NewDriveLetter C
    }

    if ($partD) {
        Write-Host "Data partition incorrectly labeled. Relabeling partition to D."
        Set-Partition -DiskNumber $partD.DiskNumber -PartitionNumber $partD.PartitionNumber -NewDriveLetter D
    }
}

Write-Host "Partition labeling check and adjustments complete."

# D: persists across deployments and contains WIMs, bootstrap executables, and secrets.
# Restrict it before inspecting or reusing any cached content.
Protect-ProvisioningDrive -Fresh:(-not $skipPartitioning)

## Show if needed
#<#
foreach ($partition in $partitions) {
    Write-Host "Partition $($partition.DriveLetter):"
    Write-Host "   File System: $($partition.FileSystem)"
    Write-Host "   Capacity: $($partition.Size / 1GB) GB"
    Write-Host "   Free Space: $($partition.SizeRemaining / 1GB) GB"
    Write-Host ""
}
#>

## It seems like the Z: drive needs to be access before script exits to presists

$source_dir = "Z:\"
$local_install = "D:\"
Write-host "Source_dir is $source_dir"
Write-host "Needed image is $neededImage"
$source_install = $source_dir + "Images\" + $neededImage
Write-host "Source install is $source_install"
$OS_files = $local_install + $neededImage
$setup = $OS_files + "\setup.exe"
$secret_dir = $local_install + "secrets"
$secret_file_name = $WorkerPool + "-" + $secret_date + ".yaml"
Write-Host "Secret file name is $secret_file_name"
$secret_file = $secret_dir + "\" + $secret_file_name
$source_secrets = $source_dir + "secrets\" + $secret_file_name
$source_secrets_pat = $source_dir + "secrets\pat.txt"
Write-host "Source secrets is $source_secrets"
$source_AZsecrets = $source_dir + "secrets\" + "azcredentials.yaml"
$AZsecret_file = $secret_dir + "\azcredentials.yaml"
$PATsecret_file = $secret_dir + "\pat.txt"
$source_scripts = $source_dir + "scripts\"
$local_scripts = $local_install + "scripts\"
$local_yaml_dir = $local_install + "yaml"
$local_yaml = $local_install + "yaml\pools.yaml"
$unattend = $OS_files + "\autounattend.xml"
$source_app = $source_dir + "applications"
$local_app = $local_install + "applications"


# Resync the local deploy files from the share only when they're actually missing. The
# sentinel for setup-media deploys is setup.exe; baked-WIM deploys require both the WIM and
# its adjacent SHA-256 sidecar.
# D: PERSISTS across (re)deploys when partitioning is skipped, so keying only on setup.exe made
# the WIM path ALWAYS wipe D:\* and recopy the ~6 GB WIM every single deploy. Also require the
# needed WIM to be absent, so a same-image redeploy reuses the cached WIM. (Get-Bootstrap +
# pools.yml are refreshed separately from GitHub, so skipping the resync doesn't stale those;
# on an image change the new WIM name is absent -> resync runs and wipes the old one.)
$needWim = Join-Path $OS_files "$neededImage.wim"
$needWimHash = "$needWim.sha256"
$shareMounted = $false
if ((!(Test-Path $setup)) -and ((!(Test-Path $needWim)) -or (!(Test-Path $needWimHash)))) {
    Write-Host "Install files wrong or missing."
    Write-Host "Will resync files."
    if ((Get-ChildItem -Path $local_install -Force).Count -gt 0) {
        Write-Host Wrong install files - REMOVING
        Remove-Item -Path "${local_install}*" -Recurse -Force -ErrorAction SilentlyContinue
    }

    Mount-ZDrive
    $shareMounted = $true

    Write-Host "Copying needed files"
    Write-Host "Creating $local_app"
    New-Item -ItemType Directory $local_app  | Out-Null
    Write-Host "Creating $local_yaml_dir"
    New-Item -ItemType Directory $local_yaml_dir  | Out-Null

    Write-host "Copying $source_install to $local_install"
    Copy-Item -Path $source_install -Destination $local_install -Recurse -Force
    Write-host "Copying $source_scripts to $local_scripts"
    Copy-Item -Path $source_scripts $local_scripts -Recurse -Force
    Write-host "Copying $source_app\* to $local_app"
    Copy-Item -Path $source_app\* $local_app -Recurse -Force

}
else {
    Write-Host "Local installation image is good. No image resync needed."
}

# Secrets are small and may rotate independently of the cached image, so refresh them on
# every deployment. Bootstrap still needs both files until its Puppet run succeeds.
if (-not $shareMounted) { Mount-ZDrive }
New-Item -ItemType Directory -Path $secret_dir -Force | Out-Null
Write-Host "Refreshing $source_secrets -> $secret_file"
Copy-Item -Path $source_secrets -Destination $secret_file -Force -ErrorAction Stop
Write-Host "Refreshing $source_secrets_pat -> $PATsecret_file"
Copy-Item -Path $source_secrets_pat -Destination $PATsecret_file -Force -ErrorAction Stop
Write-Host "Disconecting Deployment Share."
Remove-PSDrive -Name Z -Scope Global -Force -ErrorAction SilentlyContinue

if ((-not (Test-Path -LiteralPath $secret_file -PathType Leaf)) -or
    (-not (Test-Path -LiteralPath $PATsecret_file -PathType Leaf))) {
    throw 'Required provisioning secrets were not refreshed on D:.'
}

# The populated answer file contains the current node name and Administrator password.
# Regenerate it every deployment rather than treating it as part of the persistent image cache.
$splat = @{
    Url  = "https://raw.githubusercontent.com/mozilla-platform-ops/worker-images/$workerImagesRevision/provisioners/windows/MDC1Windows/base-autounattend.xml"
    Path = $unattend
    PAT  = Get-Content $PATsecret_file
}
Invoke-DownloadWithRetryGithub @splat

$secret_YAML = Convertfrom-Yaml (Get-Content $secret_file -raw)
$DiskNumber = (Get-Partition -DriveLetter C).DiskNumber
$PartitionNumber = (Get-Partition -DriveLetter C).PartitionNumber
$content2 = (Get-Content -Path $unattend -Raw).
    Replace('THIS-IS-A-NAME', $shortname).
    Replace('<DiskID>0</DiskID>', "<DiskID>$DiskNumber</DiskID>").
    Replace('<PartitionID>3</PartitionID>', "<PartitionID>$PartitionNumber</PartitionID>")

$adminPassword = [string]$secret_YAML.win_adminpw
if ([string]::IsNullOrWhiteSpace($adminPassword)) { throw 'win_adminpw is missing from the deployment secrets.' }
$unattendXml = New-Object System.Xml.XmlDocument
$unattendXml.PreserveWhitespace = $true
$unattendXml.LoadXml($content2)
$passwordNodes = $unattendXml.SelectNodes("//*[local-name()='Value' and text()='NotARealPassword']")
if ($passwordNodes.Count -eq 0) { throw 'No Administrator password placeholders found in the unattend template.' }
foreach ($node in $passwordNodes) { $node.InnerText = $adminPassword }
$xmlSettings = New-Object System.Xml.XmlWriterSettings
$xmlSettings.Encoding = New-Object System.Text.UTF8Encoding($false)
$xmlWriter = [System.Xml.XmlWriter]::Create($unattend, $xmlSettings)
try { $unattendXml.Save($xmlWriter) } finally { $xmlWriter.Dispose() }

if ((Get-ChildItem -Path C:\ -Force) -ne $null) {
    write-host "Previous installation detected. Formatting OS disk."
    Format-Volume -DriveLetter C -FileSystem NTFS -Force -ErrorAction Inquire | Out-Null
}

Update-GetBoot -revision $workerImagesRevision

## Update yaml files with recent changes
Copy-Item -Path pools.yml  $local_yaml -Force

Set-Location -Path $OS_files
Write-Host "Initializing OS installation."

if (Test-Path $setup) {
    ## Standard path: Windows Setup applies sources\install.wim per the unattend.
    Write-Host Running: Start-Process -FilePath $setup -ArgumentList "/unattend:$unattend"
    Write-Host (Get-DeploySendoff)
    Start-Process -FilePath $setup -ArgumentList "/unattend:$unattend"
}
else {
    ## RELOPS-2487 baked-WIM path (DISM /Apply-Image). The image folder holds no
    ## setup.exe - just a bare, already-sysprep/generalize'd <name>.wim. Apply it
    ## directly, make the disk bootable with bcdboot, and drop the (already edited)
    ## unattend where a generalized image processes it on first boot
    ## (\Windows\Panther\unattend.xml -> specialize + oobeSystem -> FirstLogonCommands
    ## -> D:\scripts\Get-Bootstrap.ps1), i.e. the same first-boot chain as the setup path.
    $wim = Join-Path $OS_files "$neededImage.wim"
    if (-not (Test-Path $wim)) {
        throw "No setup.exe and no baked WIM at '$wim' - nothing to deploy for image '$neededImage'."
    }

    $wimHash = "$wim.sha256"
    if (-not (Test-Path -LiteralPath $wimHash)) {
        throw "SHA-256 sidecar missing for baked WIM: $wimHash"
    }
    $sidecar = Get-Content -LiteralPath $wimHash -Raw
    if ($sidecar -notmatch '^\s*([0-9a-fA-F]{64})(?:\s|$)') {
        throw "Invalid SHA-256 sidecar: $wimHash"
    }
    $expectedHash = $Matches[1]
    $actualHash = (Get-FileHash -LiteralPath $wim -Algorithm SHA256).Hash
    if ($actualHash -ne $expectedHash) {
        throw "SHA-256 mismatch for $wim (expected $expectedHash, got $actualHash)"
    }
    Write-Host "== SHA-256 verified: $actualHash =="

    $winVol = "C:"   # Windows target (primary NTFS; diskpart 'assign letter=C')

    # Clean the Windows volume before applying. DISM /Apply-Image writes into the target AS-IS
    # (it does NOT format), and on a redeploy partitioning is skipped (C:/D: already labeled), so
    # C: would otherwise still hold the PREVIOUS OS and we'd layer the new image over stale files.
    # Quick-format just C: in place - keeps its drive letter (so the skip-partitioning check still
    # passes) and leaves the ESP and the persistent D: (cached WIM) untouched - for a clean apply
    # every deploy. Done AFTER the WIM existence check above so we never wipe C: then find no WIM.
    Write-Host "== Quick-formatting $winVol before apply (clean DISM target) =="
    Format-Volume -DriveLetter C -FileSystem NTFS -Force -Confirm:$false -ErrorAction Stop | Out-Null

    Write-Host "== DISM /Apply-Image '$wim' (index 1) -> $winVol\ =="
    dism.exe /Apply-Image /ImageFile:"$wim" /Index:1 /ApplyDir:"$winVol\"
    if ($LASTEXITCODE -ne 0) { throw "DISM /Apply-Image failed rc=$LASTEXITCODE" }

    ## --- Deterministically set the node name in the OFFLINE image registry ---
    ## Do it HERE in WinPE (before the OS ever boots) so the very first boot already comes up
    ## as $shortname - i.e. BEFORE the baked nxlog service starts shipping logs, so every log
    ## line reports the node name from the start. On the DISM-applied generalized image the
    ## specialize-pass <ComputerName> from the unattend was NOT taking effect, so the baked
    ## 'nuc-bake' name persisted and all logs shipped as nuc-bake (verified in SolarWinds).
    ## A post-boot Rename-Computer would need a reboot to go active and would leak nuc-bake-
    ## labelled logs until then; the offline edit avoids that. $shortname = node reverse-DNS
    ## short name (e.g. nuc13-160), the same value substituted into the unattend ComputerName.
    if ($shortname) {
        $sysHive = "$winVol\Windows\System32\config\SYSTEM"
        Write-Host "== Offline-setting ComputerName -> $shortname in $sysHive =="
        reg load "HKLM\OFFSYS" "$sysHive" | Out-Null
        try {
            reg add "HKLM\OFFSYS\ControlSet001\Control\ComputerName\ComputerName"       /v ComputerName  /t REG_SZ /d $shortname /f | Out-Null
            reg add "HKLM\OFFSYS\ControlSet001\Control\ComputerName\ActiveComputerName" /v ComputerName  /t REG_SZ /d $shortname /f | Out-Null
            reg add "HKLM\OFFSYS\ControlSet001\Services\Tcpip\Parameters"               /v Hostname      /t REG_SZ /d $shortname /f | Out-Null
            reg add "HKLM\OFFSYS\ControlSet001\Services\Tcpip\Parameters"               /v "NV Hostname" /t REG_SZ /d $shortname /f | Out-Null
        }
        finally {
            [gc]::Collect(); Start-Sleep -Seconds 1
            reg unload "HKLM\OFFSYS" | Out-Null
        }
        Write-Host "== Offline ComputerName set to $shortname =="
    }
    else {
        Write-Warning "shortname is empty - skipping offline rename; node would keep the baked name."
    }

    ## bcdboot writes the UEFI boot files (\EFI\Microsoft\Boot + BCD) to the EFI System
    ## Partition, and /s can only address it by drive letter. diskpart does 'assign
    ## letter=S' at partition time, but that letter does NOT reliably persist on a GPT
    ## system partition (observed: list volume shows the ESP with no letter -> bcdboot
    ## /s S: fails rc=87). So locate the ESP on the SAME disk as C: and give it a letter
    ## right here. Targeting C:'s disk explicitly means a leftover/stale ESP on another
    ## disk can't be picked. (TODO/disk-clutter: diskpart may not be fully cleaning the
    ## disk - a ~644 MB leftover partition was seen on nuc13-160; see WORKLOG follow-up.)
    $espGuid = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
    $cDisk = (Get-Partition -DriveLetter C).DiskNumber
    $esp = Get-Partition -DiskNumber $cDisk |
        Where-Object { $_.GptType -eq $espGuid } | Select-Object -First 1
    if (-not $esp) { throw "No EFI System Partition on disk $cDisk - cannot run bcdboot." }
    if ($esp.DriveLetter) {
        $efiVol = "$($esp.DriveLetter):"
    }
    else {
        $espDp = "select disk $cDisk`r`nselect partition $($esp.PartitionNumber)`r`nassign letter=S`r`nexit"
        $espDp | Out-File -FilePath "$env:TEMP\assign_esp.txt" -Encoding ASCII
        Start-Process "diskpart.exe" -ArgumentList "/s $env:TEMP\assign_esp.txt" -Wait
        $efiVol = "S:"
    }
    Write-Host "== ESP = disk $cDisk / partition $($esp.PartitionNumber) -> $efiVol =="

    Write-Host "== bcdboot $winVol\Windows /s $efiVol /f UEFI =="
    bcdboot.exe "$winVol\Windows" /s $efiVol /f UEFI
    if ($LASTEXITCODE -ne 0) { throw "bcdboot failed rc=$LASTEXITCODE" }

    ## Reuse the unattend the resync block already fetched + edited (ComputerName,
    ## admin password). A generalized image runs specialize + oobeSystem from
    ## \Windows\Panther\unattend.xml on first boot; the windowsPE/ImageInstall pass in
    ## it is simply ignored (the image is already applied).
    $panther = Join-Path "$winVol\" "Windows\Panther"
    New-Item -ItemType Directory -Path $panther -Force | Out-Null
    Copy-Item -Path $unattend -Destination (Join-Path $panther "unattend.xml") -Force
    Write-Host "== Placed unattend at $panther\unattend.xml =="

    ## --- Re-assert the node name AFTER specialize (RELOPS-2487) ---
    ## The offline rename above is necessary but NOT sufficient: it runs in WinPE, and the
    ## first-boot SPECIALIZE pass runs AFTER it and regenerates a random WIN-xxxxxxxx into
    ## ActiveComputerName (the unattend's <ComputerName> does not take effect on this image).
    ## Observed 2026-08-20 on nuc13-158: ComputerName=NUC13-158 but ActiveComputerName=
    ## WIN-D81J5HC82S0, with Tcpip Hostname/NV Hostname still correct. That mismatch is not
    ## cosmetic - maintainsystem-hw looked the node up under the WIN- name, missed, and
    ## Set-PXE'd into an unbreakable re-image loop, and generic-worker's workerId reads the
    ## same value.
    ##
    ## SetupComplete.cmd is the first hook that runs AFTER specialize/oobeSystem and before
    ## any logon, so it is the earliest point where the name can be made authoritative.
    ## Deliberately NOT a Rename-Computer: that cmdlet compares against the PERSISTENT name,
    ## which is already correct, so it refuses with "the new name is the same as the current
    ## name". Writing ActiveComputerName directly is the only thing that works (verified on
    ## all five canary nodes, 2026-08-20).
    $setupScripts = Join-Path "$winVol\" "Windows\Setup\Scripts"
    New-Item -ItemType Directory -Path $setupScripts -Force | Out-Null

    $nameFixPs1 = @'
# Set-ActiveComputerName.ps1 - re-assert the node name after the specialize pass.
# Reads nothing from the deploy; the authoritative value is the persistent ComputerName
# that OS-deploy.ps1 set offline, so this is safe to run unconditionally on first boot.
$log = 'C:\Windows\Temp\setupcomplete-name.log'
function W([string]$m) { "$([DateTime]::UtcNow.ToString('o')) $m" | Out-File -FilePath $log -Append -Encoding utf8 }

$cnKey  = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName'
$acnKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName'
$tcpip  = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'

try {
    $persistent = "$((Get-ItemProperty -Path $cnKey -ErrorAction Stop).ComputerName)".Trim()
    $active     = "$((Get-ItemProperty -Path $acnKey -ErrorAction SilentlyContinue).ComputerName)".Trim()
    W "persistent=$persistent active=$active"

    if (-not $persistent) { W 'persistent ComputerName empty - nothing to assert'; exit 0 }
    if ($active -eq $persistent) { W 'already in sync - no action'; exit 0 }

    New-ItemProperty -Path $acnKey -Name ComputerName   -Value $persistent -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $tcpip  -Name Hostname       -Value $persistent -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $tcpip  -Name 'NV Hostname'  -Value $persistent -PropertyType String -Force | Out-Null
    W "wrote ActiveComputerName/Hostname/NV Hostname = $persistent; restarting"
    Restart-Computer -Force
}
catch {
    W "FAILED: $($_.Exception.Message)"
    exit 1
}
'@

    $setupCompleteCmd = @'
@echo off
REM RELOPS-2487: re-assert the node name after specialize. See Set-ActiveComputerName.ps1.
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0Set-ActiveComputerName.ps1"
exit /b 0
'@

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $setupScripts 'Set-ActiveComputerName.ps1'), $nameFixPs1, $utf8NoBom)
    # SetupComplete.cmd must be ANSI/ASCII - cmd.exe will not parse a UTF-8 BOM.
    [System.IO.File]::WriteAllText((Join-Path $setupScripts 'SetupComplete.cmd'), $setupCompleteCmd, [System.Text.Encoding]::ASCII)
    Write-Host "== Placed SetupComplete.cmd + Set-ActiveComputerName.ps1 in $setupScripts =="

    Write-Host "Baked WIM applied. Rebooting into the deployed OS. $(Get-DeploySendoff)"
    Start-Sleep -Seconds 5
    wpeutil reboot
}
