param(
    [string]$deployuser,
    [string]$deploymentaccess
)
function Deploy-Dev-OS {
    param (
        [string]$Password
    )

    $local_dir = "X:\working"
    $source = "https://raw.githubusercontent.com/mozilla-platform-ops/ronin_puppet/win11hardware/provisioners/windows/MDC1Windows/dev"
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
        } catch {
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
    powershell $deploy_script -deployuser "deployment" -deploymentaccess "$Password"
}

function Mount-ZDrive {
    param(
    )
    ## Mount Deployment share
    ## PSDrive is will unmount when the Powershell sessions ends. Ultimately maybe OK.
    ## net use will presist
    $deploypw = ConvertTo-SecureString -String $deploymentaccess -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($deployuser, $deploypw)

    $maxRetries = 20
    $retryInterval = 30

    Write-Host "Mounting Deployment Share."
    for ($retryCount = 1; $retryCount -le $maxRetries; $retryCount++) {
        try {
            net use Z: \\mdt2022.ad.mozilla.com\deployments /user:$deployuser $deploymentaccess /persistent:yes
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
function Update-GetBoot {
    param(
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
        URI     = "https://raw.githubusercontent.com/mozilla-platform-ops/worker-images/refs/heads/main/provisioners/windows/MDC1Windows/Get-Bootstrap.ps1"
        OutFile = $Template_Get_Bootstrap
    }

    Invoke-WebRequest @bootstrapSplat

    Write-Host "Updating Get-Bootstrap.ps1"

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
assign letter=D
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
} else {
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
    } elseif ($diskCount -eq 1) {
        # Only one disk found, use it for both C and D
        $singleDisk = $disks[0].Number
        Write-Host "Only one disk found. Setting up C and D partitions on the same disk."
        PartitionAndFormat-SingleDisk -DiskNumber $singleDisk
    } else {
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
} elseif ($disks.Count -eq 1) {
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
## Get node name

$Ethernet = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object { $_.name -match "ethernet" }
try {
    $IPAddress = ($Ethernet.GetIPProperties().UnicastAddresses |
        Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and $_.Address.IPAddressToString -ne "127.0.0.1" } |
        Select-Object -ExpandProperty Address).IPAddressToString

    if (-not $IPAddress) {
        throw "No IP address found using .NET method."
    }
} catch {
    $NetshOutput = netsh interface ip show addresses
    $IPAddress = ($NetshOutput -match "IP Address" | ForEach-Object {
        if ($_ -notmatch "127.0.0.1") {
            $_ -replace ".*?:\s*", ""
        }
    }).Trim()
}

if ($IPAddress) {
    Write-Host "IP Address: $IPAddress"
} else {
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
## Assumes files is in the same dir
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
            Write-Output "The associated image for $shortname is: $neededImage"
            if ($pool.dev -eq $true) {
                Deploy-Dev-OS -Password $deploymentaccess
                Write-Host "Dev mode is enabled."
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
            $puppet_version = "6.28.0"
        }
    }
}

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
Write-host "Source secrets is $source_secrets"
$source_AZsecrets = $source_dir + "secrets\" + "azcredentials.yaml"
$AZsecret_file = $secret_dir + "\azcredentials.yaml"
$source_scripts = $source_dir + "scripts\"
$local_scripts = $local_install + "scripts\"
$local_yaml_dir = $local_install + "yaml"
$local_yaml = $local_install + "yaml\pools.yaml"
$unattend = $OS_files + "\autounattend.xml"
$source_app = $source_dir + "applications"
$local_app = $local_install + "applications"


if (!(Test-Path $setup)) {
    Write-Host "Install files wrong or missing."
    Write-Host "Will resync files."
    if ((Get-ChildItem -Path $local_install -Force).Count -gt 0) {
        Write-Host Wrong install files - REMOVING
        Remove-Item -Path "${local_install}*" -Recurse -Force -ErrorAction SilentlyContinue
    }

    Mount-ZDrive

    Write-Host "Copying needed files"
    Write-Host "Creating $secret_dir"
    New-Item -ItemType Directory $secret_dir  | Out-Null
    Write-Host "Creating $local_app"
    New-Item -ItemType Directory $local_app  | Out-Null
    Write-Host "Creating $local_yaml_dir"
    New-Item -ItemType Directory $local_yaml_dir  | Out-Null

    Write-host "Copying $source_install to $local_install"
    Copy-Item -Path $source_install -Destination $local_install -Recurse -Force
    Write-Host "Copying $source_secrets to $secret_file"
    Copy-Item -Path $source_secrets -Destination $secret_file -Force
    Write-Host "Copying $source_AZsecrets to $AZsecret_file"
    Copy-Item -Path $source_AZsecrets -Destination $AZsecret_file -Force
    Write-host "Copying $source_scripts to $local_scripts"
    Copy-Item -Path $source_scripts $local_scripts -Recurse -Force
    Write-host "Copying $source_app\* to $local_app"
    Copy-Item -Path $source_app\* $local_app -Recurse -Force

    Update-GetBoot

    Write-Host "Disconecting Deployment Share."
    net use Z: /delete

    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/mozilla-platform-ops/worker-images/main/provisioners/windows/MDC1Windows/base-autounattend.xml"  -OutFile $unattend

    $secret_YAML = Convertfrom-Yaml (Get-Content $secret_file -raw)

    Write-Host "Updating autounattend.xml."

    $DiskNumber = ((Get-Partition -DriveLetter C).DiskNumber)
    $install_to = "<DiskID>$DiskNumber</DiskID>"
    $PartitionNumber = (Get-Partition -DriveLetter C).PartitionNumber
    $partition = "<PartitionID>$PartitionNumber</PartitionID>"

    $replacetheses = @(
        @{ OldString = "THIS-IS-A-NAME"; NewString = $shortname },
        @{ OldString = "<DiskID>0</DiskID>"; NewString = $install_to },
        @{ OldString = "<PartitionID>3</PartitionID>"; NewString = $partition },
        @{ OldString = "NotARealPassword"; NewString = $secret_YAML.win_adminpw }
    )

    $content2 = Get-Content -Path $unattend
    foreach ($replacethese in $replacetheses) {
        $content2 = $content2 -replace $replacethese.OldString, $replacethese.NewString
    }

    Set-Content -Path $unattend -Value $content2
}
elseif (!(Test-Path $secret_file)) {
    Get-ChildItem -Path $secret_dir | Remove-Item -Recurse
    Mount-ZDrive
    Write-host "Updating secret file."
    Copy-Item -Path $source_secrets -Destination $secret_file -Force
    Copy-Item -Path $source_AZsecrets -Destination $AZsecret_file -Force
    #Copy-Item -Path $source_scripts\Get-Bootstrap.ps1 $local_scripts\Get-Bootstrap.ps1 -Recurse -Force
    Write-Host "Disconecting Deployment Share."
    net use Z: /delete
    Update-GetBoot
}
else {
    Write-Host "Local installation files are good. No further action needed."
    Update-GetBoot
}
if ((Get-ChildItem -Path C:\ -Force) -ne $null) {
    write-host "Previous installation detected. Formatting OS disk."
    Format-Volume -DriveLetter C -FileSystem NTFS -Force -ErrorAction Inquire | Out-Null
}



## Update yaml files with recent changes
Copy-Item -Path pools.yml  $local_yaml -Force

Set-Location -Path $OS_files
Write-Host "Initializing OS installation."
Write-Host Running: Start-Process -FilePath $setup -ArgumentList "/unattend:$unattend"
Write-Host "Have a nice day! :)"
Start-Process -FilePath $setup -ArgumentList "/unattend:$unattend"
