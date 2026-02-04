param(
    [switch]$single,
    [switch]$pool,
    [string]$node,
    [string]$pool_name,

    # Environment + paths
    [string]$domain_suffix = "wintest2.releng.mdc1.mozilla.com",
    [string]$yaml_url      = "https://raw.githubusercontent.com/mozilla-platform-ops/worker-images/refs/heads/main/provisioners/windows/MDC1Windows/pools.yml",

    # Output
    [string]$output_dir    = "C:\logs",
    [string]$output_name   = "",   # optional override; otherwise auto-named

    # Behavior flags
    [int]$sleep_secs = 30,   # sleep between pass 1 -> pass 2 (retry)
    [switch]$quick,          # shortcut to set sleep to 5 seconds

    # Dry-run
    [switch]$dry_run,        # print actions only; do not SSH

    [switch]$help
)

if ($quick) { $sleep_secs = 5 }

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ------------------ Globals / Tracking ------------------
$script:failed_ssh        = @()
$script:retry_attempted   = @()
$script:retry_recovered   = @()

# ------------------ Helpers ------------------
function Ensure-Dir {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Sleep-BetweenPasses {
    param([int]$Seconds,[string]$From = "",[string]$To = "")
    Write-Host ""
    if ($From -or $To) { Write-Host ("---- Sleeping {0}s before {1} -> {2} ----" -f $Seconds,$From,$To) }
    else { Write-Host ("---- Sleeping {0}s before next pass ----" -f $Seconds) }
    Start-Sleep -Seconds $Seconds
    Write-Host ""
}

function Invoke-SSH {
    param(
        [Parameter(Mandatory)][string]$NodeName,
        [Parameter(Mandatory)][string]$Command
    )
    $output = & ssh -q -o ConnectTimeout=5 -o UserKnownHostsFile=empty.txt -o StrictHostKeyChecking=no $NodeName $Command
    [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
}

function Encode-PSCommand {
    param([Parameter(Mandatory)][string]$Command)
    $pref = @"
`$ProgressPreference='SilentlyContinue';
`$VerbosePreference='SilentlyContinue';
`$InformationPreference='SilentlyContinue';
`$WarningPreference='SilentlyContinue';
"@
    $full = "$pref $Command"
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($full)
    [Convert]::ToBase64String($bytes)
}

function Invoke-SSHPS {
    param([Parameter(Mandatory)][string]$NodeName,[Parameter(Mandatory)][string]$PsCommand)
    $enc = Encode-PSCommand -Command $PsCommand
    Invoke-SSH -NodeName $NodeName -Command ("powershell -NoLogo -NonInteractive -NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc")
}

# ------------------ CLI UX ------------------
if (-not $single -and -not $pool -and -not $help) {
    $choice = Read-Host "Neither single nor pool parameters were provided. Enter `n'1' - single node `n'2' - entire pool `n'3' - help `n'q' - quit `n"
    switch ($choice) {
        '1' { $single=$true }
        '2' { $pool=$true }
        '3' { $help=$true }
        'q' { Write-Host "Exiting script."; exit }
        default { Write-Host "Invalid choice."; $help=$true }
    }
}

if ($help) {
@"
Usage: CollectHWInfo.ps1 [options]

Options:
  -single                 : Operate on a single node.
  -node                   : Node name when using -single.
  -pool                   : Operate on an entire pool of nodes.
  -pool_name              : Pool name when using -pool.

  -domain_suffix <suffix> : FQDN suffix (default: $domain_suffix)
  -yaml_url <url>         : Pools YAML URL

  -output_dir <path>      : Local directory for CSV output (default: $output_dir)
  -output_name <file.csv> : Optional output filename override
  -sleep_secs <n>         : Sleep between pass 1 -> retry pass (default $sleep_secs; use -quick for 5s)
  -quick                  : Shortcut to set sleep between passes to 5 seconds.
  -dry_run                : DRY RUN (no SSH; just prints intended actions).
  -help                   : Show this help.

SSH config example:
  Host *.$domain_suffix
    User administrator
    IdentityFile ~/.ssh/win_audit_id_rsa
"@ | Write-Host
    exit
}

# ------------------ Pool Data ------------------
Write-Host "Pulling pool data from $yaml_url"
$YAML = Invoke-WebRequest -Uri $yaml_url | ConvertFrom-Yaml

# ------------------ Resolve targets ------------------
$targets = @()

if ($single) {
    if ([string]::IsNullOrWhiteSpace($node)) {
        $node = Read-Host "Enter a value for 'node'"
        if ([string]::IsNullOrWhiteSpace($node)) { Write-Host "No value provided for 'node'. Exiting."; exit }
    }
    # validate node exists in YAML somewhere
    $found = $false
    foreach ($wp in $YAML.pools) {
        if ($wp.nodes -contains $node) { $found = $true; break }
    }
    if (-not $found) { Write-Host "Node name not found in YAML."; exit 96 }

    $targets = @("$node.$domain_suffix")
}
elseif ($pool) {
    if ([string]::IsNullOrWhiteSpace($pool_name)) {
        Write-Host "Pool name required. Available pools:"
        foreach ($wp in $YAML.pools) {
            Write-Host $wp.name
            if ($wp.PSObject.Properties.Name -contains 'Description') { Write-Host "Description: $($wp.Description)" }
            Write-Host
        }
        $pool_name = Read-Host "Enter pool name"
        if ([string]::IsNullOrWhiteSpace($pool_name)) { Write-Host "No pool name provided. Exiting."; exit }
    }

    $pool_names = @($YAML.pools.name)
    if ($pool_names -notcontains $pool_name) { Write-Host "$pool_name is not a valid pool name. Exiting."; exit 97 }

    $nodes = ($YAML.pools | Where-Object { $_.name -eq $pool_name }).nodes
    $targets = $nodes | ForEach-Object { "$_.$domain_suffix" }
}

# ------------------ Remote collector payload ------------------
# Emits ONE JSON object to stdout (compressed), which we parse locally.
$collectorPs = @"
`$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Safe(`$sb, `$default=`$null) { try { & `$sb } catch { `$default } }
function GB([int64]`$b){ if(-not `$b -or `$b -le 0){ return `$null }; [math]::Round((`$b/1GB),2) }

function Get-FirmwareType {
  # 1) Best signal when available
  `$ft = Safe { (Get-ComputerInfo -Property BiosFirmwareType).BiosFirmwareType }
  if (`$ft) { return [string]`$ft }

  # 2) Registry hint (not always present)
  `$pe = Safe { (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'PEFirmwareType' -ErrorAction Stop).PEFirmwareType }
  if (`$pe -eq 1) { return 'BIOS' }
  if (`$pe -eq 2) { return 'UEFI' }

  # 3) SecureBoot state key is typically present only on UEFI systems
  `$sbState = Safe { Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction Stop }
  if (`$sbState) { return 'UEFI' }

  # 4) If Confirm-SecureBootUEFI can run at all, system is UEFI (it may return True/False)
  try { Confirm-SecureBootUEFI | Out-Null; return 'UEFI' } catch {}

  return 'Unknown'
}

function Format-WmiDate([string]`$WmiDate) {
  if (-not `$WmiDate) { return `$null }
  try { return ([Management.ManagementDateTimeConverter]::ToDateTime(`$WmiDate)).ToString('yyyy-MM-dd') } catch { return `$null }
}

`$os   = Safe { Get-CimInstance Win32_OperatingSystem }
`$cs   = Safe { Get-CimInstance Win32_ComputerSystem }
`$bb   = Safe { Get-CimInstance Win32_BaseBoard }
`$bios = Safe { Get-CimInstance Win32_BIOS }
`$cpu  = Safe { Get-CimInstance Win32_Processor | Select-Object -First 1 }
`$mem  = Safe { Get-CimInstance Win32_PhysicalMemory }
`$gpus = Safe { Get-CimInstance Win32_VideoController }

`$totalMemBytes = Safe { [int64]`$cs.TotalPhysicalMemory } (Safe { (`$mem | Measure-Object -Property Capacity -Sum).Sum } 0)
`$firmwareType = Get-FirmwareType

# BIOS version strings
`$biosVersionJoined = Safe { (`$bios.BIOSVersion -join ' | ') }
`$smbiosBiosVersion = Safe { `$bios.SMBIOSBIOSVersion }
`$biosMfg           = Safe { `$bios.Manufacturer }
`$biosRelease       = Format-WmiDate (Safe { `$bios.ReleaseDate })

[pscustomobject]@{
  Timestamp            = (Get-Date).ToString('s')
  Hostname             = `$env:COMPUTERNAME

  OS_Caption           = `$os.Caption
  OS_Version           = `$os.Version
  OS_BuildNumber       = `$os.BuildNumber

  System_Manufacturer  = `$cs.Manufacturer
  System_Model         = `$cs.Model

  BaseBoard_Manufacturer= `$bb.Manufacturer
  BaseBoard_Product    = `$bb.Product

  CPU_Name             = `$cpu.Name
  CPU_Manufacturer     = `$cpu.Manufacturer
  CPU_Cores            = `$cpu.NumberOfCores
  CPU_LogicalProcessors= `$cpu.NumberOfLogicalProcessors
  CPU_MaxClockMHz      = `$cpu.MaxClockSpeed

  Memory_TotalGB       = (GB `$totalMemBytes)
  Memory_ModuleCount   = @(`$mem).Count

  Firmware_Type        = `$firmwareType

  BIOS_Manufacturer      = `$biosMfg
  BIOS_SMBIOSBIOSVersion = `$smbiosBiosVersion
  BIOS_BIOSVersion       = `$biosVersionJoined
  BIOS_SMBIOSVersion     = ('{0}.{1}' -f `$bios.SMBIOSMajorVersion, `$bios.SMBIOSMinorVersion)
  BIOS_ReleaseDate       = `$biosRelease

  GPU_Count            = @(`$gpus).Count
  GPU_Names            = (@(`$gpus | Select-Object -ExpandProperty Name) -join ' | ')
  GPU_DriverVersions   = (@(`$gpus | Select-Object -ExpandProperty DriverVersion) -join ' | ')
} | ConvertTo-Json -Depth 5 -Compress
"@

# ------------------ Collection ------------------
function Collect-FromNode {
    param([Parameter(Mandatory)][string]$Fqdn)

    if ($dry_run) {
        Write-Host "[$Fqdn] DRY RUN: would SSH and collect HW info."
        return $null
    }

    $res = Invoke-SSHPS -NodeName $Fqdn -PsCommand $collectorPs
    $out = ($res.Output | Out-String).Trim()

    if ($res.ExitCode -eq 255) {
        Write-Host "[$Fqdn] SSH connection failed."
        if ($script:failed_ssh -notcontains $Fqdn) { $script:failed_ssh += $Fqdn }
        return $null
    }

    if ($res.ExitCode -ne 0) {
        Write-Host "[$Fqdn] Remote collection failed (exit $($res.ExitCode))."
        if ($script:failed_ssh -notcontains $Fqdn) { $script:failed_ssh += $Fqdn }
        return $null
    }

    try {
        $obj = $out | ConvertFrom-Json
        if ($pool -and $pool_name) { $obj | Add-Member -NotePropertyName Pool -NotePropertyValue $pool_name -Force }
        return $obj
    } catch {
        Write-Host "[$Fqdn] Output was not valid JSON."
        if ($script:failed_ssh -notcontains $Fqdn) { $script:failed_ssh += $Fqdn }
        return $null
    }
}

# ------------------ PASS 1 ------------------
Write-Host ""
Write-Host "------------------------------------------------------------"
Write-Host "              PASS 1 (COLLECT HW INFO VIA SSH)              "
Write-Host "                    Dry run: $dry_run                       "
Write-Host "------------------------------------------------------------"
Write-Host ""

$results = @()

foreach ($fqdn in $targets) {
    Write-Host "Connecting to $fqdn"
    $obj = Collect-FromNode -Fqdn $fqdn
    if ($obj) { $results += $obj }
}

# Sleep before retry pass
Sleep-BetweenPasses -Seconds $sleep_secs -From "PASS 1 (Collect)" -To "PASS 2 (Retry SSH failures)"

# ------------------ PASS 2 (Retry SSH failures once) ------------------
function Invoke-RetryFailedSSH {
    $targets = @($script:failed_ssh | Sort-Object -Unique)
    if ($targets.Count -eq 0) {
        Write-Host "No SSH failures to retry. Skipping PASS 2."
        return
    }

    Write-Host ""
    Write-Host "------------------------------------------------------------"
    Write-Host "        PASS 2 (RETRY SSH FAILURES ONCE, COLLECT AGAIN)      "
    Write-Host "------------------------------------------------------------"
    Write-Host ""

    $script:retry_attempted = $targets
    $script:failed_ssh = @()

    foreach ($fqdn in $targets) {
        Write-Host "Retrying $fqdn"
        $obj = Collect-FromNode -Fqdn $fqdn
        if ($obj) {
            $results += $obj
            if ($script:retry_recovered -notcontains $fqdn) { $script:retry_recovered += $fqdn }
        }
    }
}

Invoke-RetryFailedSSH

# ------------------ Output CSV ------------------
Ensure-Dir -Path $output_dir

$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
if ([string]::IsNullOrWhiteSpace($output_name)) {
    $tag = if ($single) { $node } else { $pool_name }
    $output_name = "hw_inventory_{0}_{1}.csv" -f $tag, $stamp
}
$outCsv = Join-Path $output_dir $output_name

if ($dry_run) {
    Write-Host ""
    Write-Host "DRY RUN: would write CSV to $outCsv"
} else {
    # Add Error rows for hosts with no result
    $allTargets = @($targets | Sort-Object -Unique)
    $okHostnames = @($results | ForEach-Object { $_.Hostname }) | Sort-Object -Unique

    foreach ($fqdn in $allTargets) {
        $short = $fqdn -replace ("\." + [regex]::Escape($domain_suffix) + "$"), ""
        if ($okHostnames -notcontains $short -and $okHostnames -notcontains $fqdn) {
            $results += [pscustomobject]@{
                Timestamp = (Get-Date).ToString("s")
                Hostname  = $short
                Pool      = $(if ($pool) { $pool_name } else { "" })
                Error     = "No result (SSH/collection failed)"
            }
        }
    }

    $results | Export-Csv -Path $outCsv -NoTypeInformation -Encoding UTF8
    Write-Host ""
    Write-Host "Wrote CSV: $outCsv"
}

# ------------------ Final Summaries ------------------
Write-Host ""
Write-Host "==== SUMMARY ===="
Write-Host "Dry run: $dry_run"
Write-Host ""

Write-Host "Nodes that failed SSH/collection (after retry):"
if (@($script:failed_ssh).Count -gt 0) {
    (@($script:failed_ssh | Sort-Object -Unique)) | ForEach-Object { Write-Host "- $_" }
} else {
    Write-Host "- none"
}

Write-Host ""
Write-Host "Nodes that recovered on retry:"
if (@($script:retry_recovered).Count -gt 0) {
    (@($script:retry_recovered | Sort-Object -Unique)) | ForEach-Object { Write-Host "- $_" }
} else {
    Write-Host "- none"
}