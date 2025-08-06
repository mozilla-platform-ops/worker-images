param(
    [switch]$single,
    [switch]$range,
    [switch]$pool,
    [string]$node,
    [string]$hw_class,
    [string]$start,
    [string]$end,
    [string]$pool_name,
    [string]$domain_suffix = "wintest2.releng.mdc1.mozilla.com",
    [string]$audit_script = "C:\management_scripts\pool_audit.ps1",
    [string]$yaml_url = "https://raw.githubusercontent.com/mozilla-platform-ops/worker-images/refs/heads/main/provisioners/windows/MDC1Windows/pools.yml",
    [switch]$help
)

$script:failed_ssh = @()
$script:failed_script = @()
$script:wrong_config = @()
$script:PXEcounter = 0

function Invoke-SSHCommand {
    param (
        [string]$Command,
        [string]$NodeName
    )
    $sshOutput = & ssh -q -o ConnectTimeout=5 -o UserKnownHostsFile=empty.txt -o StrictHostKeyChecking=no $NodeName $Command
    return @{ ExitCode = $LASTEXITCODE; Output = $sshOutput }
}

function Run-SSHScript {
    param (
        [string]$Command,
        [string]$NodeName
    )
    ssh -q -o ConnectTimeout=5 -o UserKnownHostsFile=empty.txt -o StrictHostKeyChecking=no $NodeName "powershell -file $Command"
}

function Set-LocalPXE {
    param ()

    Write-Host "Creating PXE boot script directly on remote machine."

    $remoteScript = @'
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
    'DEBUG' { $entryType = 'SuccessAudit'; $eventId = 2; break }
    'WARN'  { $entryType = 'Warning'; $eventId = 3; break }
    'ERROR' { $entryType = 'Error'; $eventId = 4; break }
    default { $entryType = 'Information'; $eventId = 1; break }
  }
  Write-EventLog -LogName $logName -Source $source -EntryType $entryType -Category 0 -EventID $eventId -Message $message
  if ([Environment]::UserInteractive) {
    $fc = @{ 'Information' = 'White'; 'Error' = 'Red'; 'Warning' = 'DarkYellow'; 'SuccessAudit' = 'DarkGray' }[$entryType]
    Write-Host $message -ForegroundColor $fc
  }
}

function Set-PXE {
  param ()
  Write-Log -message ('{0} :: begin - {1:o}' -f $MyInvocation.MyCommand.Name, (Get-Date).ToUniversalTime()) -severity 'DEBUG'

  $tempPath = "C:\\temp\\"
  New-Item -ItemType Directory -Force -Path $tempPath -ErrorAction SilentlyContinue
  bcdedit /enum firmware > "$tempPath\\firmware.txt"

  $fwBootMgr = Select-String -Path "$tempPath\\firmware.txt" -Pattern "{fwbootmgr}"
  if (!$fwBootMgr) {
    Write-Log -message ('{0} :: Device is configured for Legacy Boot. Exiting!' -f $MyInvocation.MyCommand.Name) -severity 'DEBUG'
    Exit 999
  }

  try {
    $pxeGUID = (( Get-Content "$tempPath\\firmware.txt" | Select-String "IPV4|EFI Network" -Context 1 -ErrorAction Stop ).context.precontext)[0]
    $pxeGUID = '{' + $pxeGUID.split('{')[1]
    bcdedit /set "{fwbootmgr}" bootsequence "$pxeGUID"
    Write-Log -message ('{0} :: Device will PXE boot. Restarting' -f $MyInvocation.MyCommand.Name) -severity 'DEBUG'
    Restart-Computer -Force
  } catch {
    Write-Log -message ('{0} :: Unable to set next boot to PXE. Exiting!' -f $MyInvocation.MyCommand.Name) -severity 'DEBUG'
    Exit 888
  }

  Write-Log -message ('{0} :: end - {1:o}' -f $MyInvocation.MyCommand.Name, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
}

Set-PXE
'@

    $escapedScript = $remoteScript -replace '`', '``' -replace '"', '`"' -replace '\$', '`$'
    $heredocCommand = "powershell -Command `"Set-Content -Path 'C:\SetPXE.ps1' -Value `"$escapedScript`"`""
    Invoke-SSHCommand -Command $heredocCommand -NodeName $NodeName

    Write-Host "Running PXE script remotely."
    Run-SSHScript -Command "C:\SetPXE.ps1" -NodeName $NodeName
    $script:PXEcounter++
}

function Invoke-AuditScript {
    param (
        [string]$AuditScript,
        [string]$GitHash,
        [string]$WorkerPool,
        [string]$NodeName,
        [string]$image_name
    )

    $auditCommand = "$AuditScript -git_hash $GitHash -worker_pool_id $WorkerPool -image_name $image_name"

    try {
        Run-SSHScript -Command $auditCommand -NodeName $NodeName
        switch ($LASTEXITCODE) {
            0 {
                Write-Host "Audit script completed successfully."
            }
            255 {
                Write-Host "SSH connection failed."
                $script:failed_ssh += "$NodeName"
            }
            Default {
                Write-Host "Remote script execution failed. Attempting to PXE..."
                $script:failed_script += "$NodeName"
                Set-LocalPXE
            }
        }
    } catch {
        Write-Error "Exception running audit script: $_"
        $script:failed_script += "$NodeName"
        Set-LocalPXE
    }
}

# -- Help message --
if (-not $single -and -not $range -and -not $pool -and -not $help) {
    $choice = Read-Host "Choose: 1 - single node, 2 - entire pool, 3 - help, q - quit"
    switch ($choice) {
        '1' { $single = $true }
        '2' { $pool = $true }
        '3' { $help = $true }
        'q' { exit }
        default { Write-Host "Invalid"; exit }
    }
}

if ($help) {
    Write-Host @"
Usage: script.ps1 [options]
  -single       : Single node mode.
  -node         : Name of the node.
  -pool         : Run on pool of nodes.
  -pool_name    : Name of the pool.
  -help         : Show this message.
"@
    exit
}

# -- Load YAML config --
Write-Host "Pulling pool data from $yaml_url"
$YAML = Invoke-WebRequest -Uri $yaml_url | ConvertFrom-Yaml

# -- Single node mode --
if ($single) {
    if (-not $node) {
        $node = Read-Host "Enter node name"
        if (-not $node) { Write-Host "No node name. Exiting."; exit }
    }
    $node_name = "$node.$domain_suffix"

    foreach ($worker_pool in $YAML.pools) {
        if ($worker_pool.nodes -contains $node) {
            $WorkerPool = $worker_pool.name
            $hash = $worker_pool.hash
            $image_name = $worker_pool.image
            break
        }
    }
    if (-not $WorkerPool) {
        Write-Host "Node not found in any pool. Exiting."
        exit 96
    }
    Write-Host "Connecting to $node_name"
    Invoke-AuditScript -AuditScript $audit_script -GitHash $hash -WorkerPool $WorkerPool -image_name $image_name -NodeName $node_name
}

# -- Pool mode --
if ($pool) {
    if (-not $pool_name) {
        Write-Host "Available pools:"
        $YAML.pools | ForEach-Object { Write-Host "$($_.name): $($_.Description)`n" }
        $pool_name = Read-Host "Enter pool name"
        if (-not $pool_name) { Write-Host "No pool name. Exiting."; exit }
    }

    $target_pool = $YAML.pools | Where-Object { $_.name -eq $pool_name }
    if (-not $target_pool) { Write-Host "Invalid pool. Exiting."; exit }

    foreach ($node in $target_pool.nodes) {
        $node_name = "$node.$domain_suffix"
        Write-Host "Connecting to $node_name"
        Invoke-AuditScript -AuditScript $audit_script -GitHash $target_pool.hash -WorkerPool $pool_name -image_name $target_pool.image -NodeName $node_name
        if ($script:PXEcounter -ne 0 -and $script:PXEcounter % 10 -eq 0) {
            Write-Host "Sleeping 60 seconds to let PXE connections close."
            Start-Sleep -s 60
        }
    }

    Write-Host "`n-- Summary --"
    Write-Host "Wrong config:"; $script:wrong_config
    Write-Host "Script errors:"; $script:failed_script
    Write-Host "SSH failures:" ; $script:failed_ssh

    if ($script:failed_ssh.Count -gt 0) {
        Write-Host "Retrying failed SSH after delay..."
        Start-Sleep -s 600
        $retry = $script:failed_ssh
        $script:failed_ssh = @()
        foreach ($node in $retry) {
            Write-Host "Retry: $node"
            Invoke-AuditScript -AuditScript $audit_script -GitHash $target_pool.hash -WorkerPool $pool_name -image_name $target_pool.image -NodeName $node
        }
    }
}
