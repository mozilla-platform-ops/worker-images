# StressCPU.ps1
# SSH-based prime95 torture-mode CPU stress test + throttling probe across NUC13 nodes.
#
# Runs prime95 (-t torture mode) for $duration_secs on each node and captures:
#   - CPU utilization (% Processor Time) min/max/avg + raw samples
#   - Achieved frequency (% Processor Performance) min/max/avg + raw samples
#     (>100 means turbo, <100 means CPU is below nominal - the silicon-throttle
#     fingerprint that pure CPU% cannot detect; added 2026-05-07 during the
#     RELOPS-2323 throttling investigation)
#   - Microsoft-Windows-Kernel-Processor-Power Ev37 (firmware CPU limiting)
#     and Ev55 (perf state) events that fired during the stress window
#   - prime95 self-test pass/fail counts to detect mid-run instability
#
# Modes:
#   -single -node nuc13-XXX           one node
#   -list -nodes "n1,n2,n3"           explicit list
#   -range -range_start N -range_end M     contiguous range
#   -pool -pool_name <name>           pool defined in pools.yml
#   -parallel                         run a batch concurrently (max_parallel)
#
# Login user: -ssh_user (defaults to Administrator for the wintest2 fleet).
# Output: CSV + transcript log in $output_dir (default C:\logs).
# Skip list: known-bad PSU nodes are auto-excluded from range/pool scans.
#
# Used in the RELOPS-2323 throttling investigation as the heavy multi-core
# stress test, complementing the lighter Compare-NUCHealth/Scan-NUCHealth burner.

param(
    [switch]$single,
    [switch]$pool,
    [switch]$range,
    [switch]$list,
    [string]$node,
    [string]$pool_name,
    [string[]]$nodes = @(),

    # Range mode
    [string]$range_prefix  = "nuc13",
    [int]$range_start      = 1,
    [int]$range_end        = 160,
    [int]$range_pad        = 3,

    # Environment
    [string]$domain_suffix = "wintest2.releng.mdc1.mozilla.com",
    [string]$yaml_url      = "https://raw.githubusercontent.com/mozilla-platform-ops/worker-images/refs/heads/main/provisioners/windows/MDC1Windows/pools.yml",
    [string]$ssh_user      = "Administrator",

    # Stress parameters
    [int]$duration_secs    = 180,
    [int]$retry_sleep_secs = 120,
    [int]$ssh_max_retries  = 3,
    [switch]$quick,

    # Output
    [string]$output_dir    = "C:\logs",
    [string]$output_name   = "",

    # Parallel execution
    [switch]$parallel,
    [int]$max_parallel  = 3,

    [switch]$dry_run,
    [switch]$no_retry,
    [switch]$help
)

if ($quick) { $duration_secs = 30; $retry_sleep_secs = 10 }

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:stamp           = (Get-Date).ToString("yyyyMMdd_HHmmss")
$script:failed_ssh      = @()
$script:retry_recovered = @()
$script:busy_nodes      = @()
$script:results         = @()

# ------------------ Helpers ------------------
function Ensure-Dir {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function Sleep-BetweenPasses {
    param([int]$Seconds, [string]$Label = "")
    Write-Host ""
    Write-Host ("---- Sleeping {0}s{1} ----" -f $Seconds, $(if ($Label) { " : $Label" } else { "" }))
    Start-Sleep -Seconds $Seconds
    Write-Host ""
}

function Invoke-SSH {
    param([Parameter(Mandatory)][string]$NodeName, [Parameter(Mandatory)][string]$Command, [int]$TimeoutSec = 300)
    $target = if ($NodeName -match '@') { $NodeName } else { "$ssh_user@$NodeName" }
    $psi = [System.Diagnostics.ProcessStartInfo]::new('ssh')
    $psi.Arguments              = "-o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o UserKnownHostsFile=NUL -o StrictHostKeyChecking=no $target $Command"
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $p       = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $exited  = $p.WaitForExit($TimeoutSec * 1000)
    if (-not $exited) { try { $p.Kill() } catch {} }
    $null = $outTask.Wait(10000)
    $null = $errTask.Wait(10000)
    $stdout   = if ($outTask.Status -eq 'RanToCompletion') { $outTask.Result } else { '' }
    $exitCode = if ($exited) { $p.ExitCode } else { 255 }
    $p.Dispose()
    [pscustomobject]@{ Output = $stdout; ExitCode = $exitCode }
}

function Encode-PSCommand {
    param([Parameter(Mandatory)][string]$Command)
    $pref = @"
`$ProgressPreference='SilentlyContinue';
`$VerbosePreference='SilentlyContinue';
`$InformationPreference='SilentlyContinue';
`$WarningPreference='SilentlyContinue';
"@
    $full  = "$pref $Command"
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($full)
    [Convert]::ToBase64String($bytes)
}

function Invoke-SSHPS {
    param([Parameter(Mandatory)][string]$NodeName, [Parameter(Mandatory)][string]$PsCommand)
    $enc = Encode-PSCommand -Command $PsCommand
    Invoke-SSH -NodeName $NodeName -TimeoutSec ($duration_secs + 90) -Command ("powershell -NoLogo -NonInteractive -NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc")
}

# ------------------ CLI UX ------------------
if (-not $single -and -not $pool -and -not $range -and -not $list -and -not $help) {
    $choice = Read-Host "No mode selected.`n'1' single node`n'2' pool (YAML)`n'3' range (nuc13-001..160)`n'4' explicit node list`n'5' help`n'q' quit`n"
    switch ($choice) {
        '1' { $single = $true }
        '2' { $pool   = $true }
        '3' { $range  = $true }
        '4' { $list   = $true }
        '5' { $help   = $true }
        'q' { Write-Host "Exiting."; exit }
        default { $help = $true }
    }
}

if ($help) {
@"
Usage: StressCPU.ps1 -range|-single|-pool|-list [options]

Modes:
  -range                          nuc13-001 through nuc13-160 (no YAML needed)
  -single -node <name>            single node by short name
  -pool   -pool_name <name>       all nodes in a pool (from YAML)
  -list   -nodes <n1,n2,...>      explicit comma-separated list of short names

Range options:
  -range_prefix <str>        node name prefix  (default: nuc13)
  -range_start  <n>          first node number (default: 1)
  -range_end    <n>          last node number  (default: 160)
  -range_pad    <n>          zero-pad width    (default: 3 -> nuc13-001)

Stress options:
  -duration_secs <n>         stress duration per node in seconds (default: 120)
  -quick                     shortcut: duration=30s, retry_sleep=10s

Retry options:
  -retry_sleep_secs <n>      seconds between retries (default: 120)
  -ssh_max_retries  <n>      max SSH-failure retry attempts (default: 3)

Output options:
  -output_dir  <path>        directory for CSV and log (default: C:\logs)
  -output_name <file.csv>    optional filename override
  -parallel                  run nodes concurrently instead of one at a time
  -max_parallel <n>          nodes per batch when using -parallel (default: 3)
  -dry_run                   print actions; do not SSH
  -no_retry                  skip busy and SSH retry loops (one pass only)

Examples:
  .\StressCPU.ps1 -range
  .\StressCPU.ps1 -range -duration_secs 300 -range_start 50 -range_end 100
  .\StressCPU.ps1 -single -node nuc13-077 -duration_secs 300
  .\StressCPU.ps1 -range -quick
  .\StressCPU.ps1 -list -nodes nuc13-024,nuc13-033,nuc13-042 -parallel
  .\StressCPU.ps1 -list -nodes nuc13-024,nuc13-033,nuc13-042 -parallel -duration_secs 900
"@ | Write-Host
    exit
}

# ------------------ Resolve targets ------------------
$targets = @()

if ($range) {
    if ($range_start -gt $range_end) { Write-Host "range_start > range_end. Exiting."; exit 1 }
    $targets = $range_start..$range_end |
        ForEach-Object { ("{0}-{1}" -f $range_prefix, $_.ToString("D$range_pad")) + ".$domain_suffix" }
    Write-Host ("Range: {0}-{1} through {0}-{2}  ({3} nodes)" -f
        $range_prefix,
        $range_start.ToString("D$range_pad"),
        $range_end.ToString("D$range_pad"),
        $targets.Count)
} elseif ($list) {
    if ($nodes.Count -eq 0) { Write-Host "No nodes provided. Use: -list -nodes nuc13-024,nuc13-033,..."; exit 1 }
    $targets = $nodes | ForEach-Object {
        $n = $_.Trim().ToLower() -replace ',', ''
        if ($n -notlike "*.*") { "$n.$domain_suffix" } else { $n }
    }
    Write-Host ("List mode: {0} node(s): {1}" -f $targets.Count, ($targets -join ', '))
} else {
    Write-Host "Pulling pool data from $yaml_url"
    $YAML = Invoke-WebRequest -Uri $yaml_url | ConvertFrom-Yaml

    if ($single) {
        if ([string]::IsNullOrWhiteSpace($node)) {
            $node = Read-Host "Node name"
            if ([string]::IsNullOrWhiteSpace($node)) { Write-Host "No node provided. Exiting."; exit }
        }
        $found = $false
        foreach ($wp in $YAML.pools) { if ($wp.nodes -contains $node) { $found = $true; break } }
        if (-not $found) { Write-Host "Node '$node' not found in YAML."; exit 96 }
        $targets = @("$node.$domain_suffix")
    } elseif ($pool) {
        if ([string]::IsNullOrWhiteSpace($pool_name)) {
            Write-Host "Available pools:"; $YAML.pools | ForEach-Object { Write-Host "  $($_.name)" }
            $pool_name = Read-Host "Pool name"
            if ([string]::IsNullOrWhiteSpace($pool_name)) { Write-Host "No pool provided. Exiting."; exit }
        }
        if (@($YAML.pools.name) -notcontains $pool_name) { Write-Host "'$pool_name' not a valid pool."; exit 97 }
        $targets = ($YAML.pools | Where-Object { $_.name -eq $pool_name }).nodes |
            ForEach-Object { "$_.$domain_suffix" }
    }
}

# ------------------ Skip known-problem nodes ------------------
$script:skip_nodes = @(
    # Bad PSU — will not recover without hardware replacement (went down within last 14 days as of 2026-04-22)
    "nuc13-035","nuc13-036","nuc13-059","nuc13-060","nuc13-061",
    "nuc13-068","nuc13-070","nuc13-075","nuc13-096","nuc13-112",
    "nuc13-024",  # persistent SSH failure across all runs — assumed bad PSU
    "nuc13-130","nuc13-149","nuc13-154","nuc13-155","nuc13-156","nuc13-157",
    # Known bad — other causes
    "nuc13-107",  # permanent deployment failure
    "nuc13-150"   # other issue
)

$_skipped_targets = @($targets | Where-Object {
    $short = ($_ -split '\.')[0].ToLower()
    $script:skip_nodes -contains $short
})
if ($_skipped_targets.Count -gt 0) {
    $_skipped_shorts = $_skipped_targets | ForEach-Object { ($_ -split '\.')[0].ToLower() }
    if ($single) {
        Write-Host ("WARNING: {0} is on the known-problem skip list. Proceeding anyway (single mode)." -f ($_skipped_shorts -join ', ')) -ForegroundColor Yellow
    } else {
        Write-Host ("Skipping {0} known-problem node(s): {1}" -f $_skipped_targets.Count, ($_skipped_shorts -join ', ')) -ForegroundColor Yellow
        $targets = @($targets | Where-Object {
            $short = ($_ -split '\.')[0].ToLower()
            $script:skip_nodes -notcontains $short
        })
    }
}

# ------------------ Start transcript ------------------
Ensure-Dir -Path $output_dir

$script:tag = if ($range)        { "{0}-{1}-{2}" -f $range_prefix, $range_start.ToString("D$range_pad"), $range_end.ToString("D$range_pad") }
              elseif ($single)   { $node }
              elseif ($pool)     { $pool_name }
              elseif ($list)     { "list-{0}nodes" -f $targets.Count }
              else               { "unknown" }

if (-not [string]::IsNullOrWhiteSpace($output_name)) {
    $script:tag = [System.IO.Path]::GetFileNameWithoutExtension($output_name)
}

$logFile = Join-Path $output_dir ("cpu_stress_{0}_{1}.log" -f $script:tag, $script:stamp)
Start-Transcript -Path $logFile -Append
Write-Host "Log : $logFile"
Write-Host ""

# ------------------ Remote payload ------------------
# Local variables (baked in at encode time): $duration_secs
# Remote variables (escaped with backtick): everything else
$stressPayload = @"
`$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

`$wsp=`$null
foreach(`$p in @("C:\WINDOWS\SystemTemp",`$env:TMP,`$env:TEMP,`$env:USERPROFILE)){
    if(`$p){`$c=Join-Path `$p "worker-status.json";if(Test-Path `$c){`$wsp=`$c;break}}
}
`$busy=`$false
if(`$wsp){
    try{`$j=Get-Content `$wsp -Raw|ConvertFrom-Json;if(@(`$j.currentTaskIds).Count -gt 0){`$busy=`$true}}catch{}
}

if(`$busy){
    [pscustomobject]@{Status='busy';Hostname=`$env:COMPUTERNAME}|ConvertTo-Json -Compress
}else{
    `$p95dir='C:\prime95'
    `$p95exe=Join-Path `$p95dir 'prime95.exe'
    if(-not(Test-Path `$p95dir)){New-Item -ItemType Directory -Path `$p95dir -Force|Out-Null}
    if(-not(Test-Path `$p95exe)){
        `$zip=Join-Path `$p95dir 'p95.zip'
        Invoke-WebRequest -Uri 'https://roninpuppetassets.blob.core.windows.net/binaries/p95v3019b20.win64(1).zip' -OutFile `$zip -UseBasicParsing
        Expand-Archive -Path `$zip -DestinationPath `$p95dir -Force
        Remove-Item `$zip -Force -ErrorAction SilentlyContinue
    }

    `$nc=[Environment]::ProcessorCount
    `$dur=$duration_secs

    @("V24OptionsConverted=1","WGUID_version=2","StressTester=1","UsePrimenet=0",
      "MinTortureFFT=4","MaxTortureFFT=8192","TortureMem=50","TortureTime=1",
      "TortureHyperthreading=1","V30OptionsConverted=1","NumWorkers=`$nc")-join "`r`n"|Set-Content (Join-Path `$p95dir 'prime.txt') -Encoding ASCII

    `$rf=Join-Path `$p95dir 'results.txt'
    Remove-Item `$rf -Force -ErrorAction SilentlyContinue

    `$t0=Get-Date
    `$proc=Start-Process -FilePath `$p95exe -ArgumentList '-t' -WorkingDirectory `$p95dir -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 5
    `$p95Started=-not `$proc.HasExited
    `$cpuSamples =[System.Collections.Generic.List[double]]::new()
    `$perfSamples=[System.Collections.Generic.List[double]]::new()
    if(`$p95Started){
        `$deadline=`$t0.AddSeconds(`$dur-2)
        while((Get-Date) -lt `$deadline -and -not `$proc.HasExited){
            try{
                # Sample both counters in a single Get-Counter call: utilization (% Processor Time)
                # AND achieved frequency (% Processor Performance, >100 means turbo, <100 means
                # CPU is below nominal — the silicon-throttle fingerprint).
                `$cs=(Get-Counter '\Processor(_Total)\% Processor Time','\Processor Information(_Total)\% Processor Performance' -ErrorAction Stop).CounterSamples
                `$cpuSamples.Add([math]::Round(`$cs[0].CookedValue,1))
                `$perfSamples.Add([math]::Round(`$cs[1].CookedValue,1))
            }catch{}
            Start-Sleep -Seconds 4
        }
    }
    `$p95RanFull=-not `$proc.HasExited
    Stop-Process -Id `$proc.Id -Force -ErrorAction SilentlyContinue
    Get-Process -Name prime95 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    `$t1=Get-Date

    `$sec=[math]::Round((`$t1-`$t0).TotalSeconds,2)
    `$res=if(Test-Path `$rf){(Get-Content `$rf -Raw -ErrorAction SilentlyContinue).Trim()}else{''}

    `$evs=try{
        Get-WinEvent -FilterHashtable @{
            LogName='System';ProviderName='Microsoft-Windows-Kernel-Processor-Power'
            StartTime=`$t0;EndTime=`$t1
        } -ErrorAction Stop|Where-Object{`$_.Id -in 37,55}
    }catch{@()}
    `$e37=@(`$evs|Where-Object{`$_.Id -eq 37})
    `$e55=@(`$evs|Where-Object{`$_.Id -eq 55})

    `$byp=`$e37|
        Group-Object{([regex]::Match(`$_.Message,'(?i)processor\s+(\d+)')).Groups[1].Value}|
        Sort-Object{[int]`$_.Name}|
        ForEach-Object{[pscustomobject]@{Proc=`$_.Name;Count=`$_.Count}}
    `$bpj=if(`$byp){`$byp|ConvertTo-Json -Compress}else{'[]'}

    `$p55=foreach(`$x in `$e55){
        `$m=`$x.Message
        `$pc=([regex]::Match(`$m,'(?i)processor\s+(\d+)')).Groups[1].Value
        `$mp=([regex]::Match(`$m,'Minimum performance percentage:\s+(\d+)')).Groups[1].Value
        if(`$pc -and `$mp){[pscustomobject]@{Proc=[int]`$pc;MinPct=[int]`$mp}}
    }
    `$wst=if(`$p55){(`$p55|Measure-Object MinPct -Minimum).Minimum}else{`$null}
    `$avg=if(`$p55){[math]::Round((`$p55|Measure-Object MinPct -Average).Average,1)}else{`$null}

    `$cn=(Get-WmiObject Win32_Processor|Select-Object -First 1).Name

    [pscustomobject]@{
        Status       = 'ok'
        Hostname     = `$env:COMPUTERNAME
        Timestamp    = `$t0.ToString('s')
        CPU          = `$cn
        Cores        = `$nc
        DurSec       = `$dur
        ActSec       = `$sec
        CPU_MinPct   = if(`$cpuSamples.Count -gt 0){[math]::Round((`$cpuSamples|Measure-Object -Minimum).Minimum,1)}else{`$null}
        CPU_MaxPct   = if(`$cpuSamples.Count -gt 0){[math]::Round((`$cpuSamples|Measure-Object -Maximum).Maximum,1)}else{`$null}
        CPU_AvgPct   = if(`$cpuSamples.Count -gt 0){[math]::Round((`$cpuSamples|Measure-Object -Average).Average,1)}else{`$null}
        CPU_Samples  = `$cpuSamples -join ','
        Perf_MinPct  = if(`$perfSamples.Count -gt 0){[math]::Round((`$perfSamples|Measure-Object -Minimum).Minimum,1)}else{`$null}
        Perf_MaxPct  = if(`$perfSamples.Count -gt 0){[math]::Round((`$perfSamples|Measure-Object -Maximum).Maximum,1)}else{`$null}
        Perf_AvgPct  = if(`$perfSamples.Count -gt 0){[math]::Round((`$perfSamples|Measure-Object -Average).Average,1)}else{`$null}
        Perf_Samples = `$perfSamples -join ','
        P95_Started  = `$p95Started
        P95_RanFull  = `$p95RanFull
        P95_Results  = `$res
        Ev37         = `$e37.Count
        Ev37_ByProc  = `$bpj
        Ev55         = `$e55.Count
        Ev55_Worst   = `$wst
        Ev55_Avg     = `$avg
    }|ConvertTo-Json -Depth 5 -Compress
}
"@

# ------------------ Stress-Node ------------------
function Stress-Node {
    param([Parameter(Mandatory)][string]$Fqdn)

    if ($dry_run) {
        Write-Host "[$Fqdn] DRY RUN: would stress for ${duration_secs}s."
        return $null
    }

    Write-Host "[$Fqdn] Connecting..."
    $res = Invoke-SSHPS -NodeName $Fqdn -PsCommand $stressPayload
    $out = ($res.Output | Out-String).Trim()

    if ($res.ExitCode -eq 255) {
        Write-Host "[$Fqdn] SSH connection failed."
        if ($script:failed_ssh -notcontains $Fqdn) { $script:failed_ssh += $Fqdn }
        return $null
    }
    if ($res.ExitCode -ne 0) {
        Write-Host "[$Fqdn] Remote execution failed (exit $($res.ExitCode))."
        if ($script:failed_ssh -notcontains $Fqdn) { $script:failed_ssh += $Fqdn }
        return $null
    }

    try { $obj = $out | ConvertFrom-Json }
    catch {
        Write-Host "[$Fqdn] No JSON in output. Remote said:`n$out"
        if ($script:failed_ssh -notcontains $Fqdn) { $script:failed_ssh += $Fqdn }
        return $null
    }

    if ($obj.Status -eq 'busy') {
        Write-Host "[$Fqdn] Busy (task running). Will retry in ${retry_sleep_secs}s."
        return "busy"
    }

    if ($pool -and $pool_name) { $obj | Add-Member -NotePropertyName Pool -NotePropertyValue $pool_name -Force }

    Write-Host ("[$Fqdn] Done  Ev37={0}  CPU_Avg={1}%  Perf_Min={2}%  Perf_Avg={3}%  Perf_Max={4}%  Ev55_Worst={5}%  P95_Started={6}  P95_RanFull={7}  ActSec={8}" -f
        $obj.Ev37, $obj.CPU_AvgPct, $obj.Perf_MinPct, $obj.Perf_AvgPct, $obj.Perf_MaxPct, $obj.Ev55_Worst, $obj.P95_Started, $obj.P95_RanFull, $obj.ActSec)
    if ($obj.P95_Results) { Write-Host "[$Fqdn] P95: $($obj.P95_Results)" }

    return $obj
}

# ------------------ Parallel runner ------------------
function Invoke-Parallel {
    param([string[]]$Fqdns, [switch]$IsRetry)

    $rsPool   = [RunspaceFactory]::CreateRunspacePool(1, [math]::Max(1, $max_parallel))
    $rsPool.Open()
    $msgQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

    $rsScript = {
        param(
            [string]$Fqdn,
            [string]$StressPayload,
            [int]$DurationSecs,
            [bool]$DryRun,
            [bool]$PoolMode,
            [string]$PoolName,
            [string]$SshUser,
            [System.Collections.Concurrent.ConcurrentQueue[string]]$MsgQueue
        )

        function Log { param([string]$Msg) $MsgQueue.Enqueue($Msg) }

        function Invoke-SSH {
            param([string]$NodeName,[string]$Command,[int]$TimeoutSec=300)
            $target = if ($NodeName -match '@') { $NodeName } else { "$SshUser@$NodeName" }
            $psi = [System.Diagnostics.ProcessStartInfo]::new('ssh')
            $psi.Arguments              = "-o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o UserKnownHostsFile=NUL -o StrictHostKeyChecking=no $target $Command"
            $psi.UseShellExecute        = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.CreateNoWindow         = $true
            $p       = [System.Diagnostics.Process]::Start($psi)
            $outTask = $p.StandardOutput.ReadToEndAsync()
            $errTask = $p.StandardError.ReadToEndAsync()
            $exited  = $p.WaitForExit($TimeoutSec * 1000)
            if (-not $exited) { try { $p.Kill() } catch {} }
            $null = $outTask.Wait(10000)
            $null = $errTask.Wait(10000)
            $stdout   = if ($outTask.Status -eq 'RanToCompletion') { $outTask.Result } else { '' }
            $exitCode = if ($exited) { $p.ExitCode } else { 255 }
            $p.Dispose()
            [pscustomobject]@{ Output=$stdout; ExitCode=$exitCode }
        }
        function Encode-PSCommand {
            param([string]$Command)
            $pref='$ProgressPreference=''SilentlyContinue'';$VerbosePreference=''SilentlyContinue'';$InformationPreference=''SilentlyContinue'';$WarningPreference=''SilentlyContinue'';'
            $bytes=[System.Text.Encoding]::Unicode.GetBytes("$pref $Command")
            [Convert]::ToBase64String($bytes)
        }
        function Invoke-SSHPS {
            param([string]$NodeName,[string]$PsCommand)
            Invoke-SSH -NodeName $NodeName -TimeoutSec ($DurationSecs + 90) -Command ("powershell -NoLogo -NonInteractive -NoProfile -ExecutionPolicy Bypass -EncodedCommand $(Encode-PSCommand -Command $PsCommand)")
        }

        if ($DryRun) { Log "[$Fqdn] DRY RUN"; return [pscustomobject]@{_s='dry';Fqdn=$Fqdn} }

        Log "[$Fqdn] Connecting..."
        $res = Invoke-SSHPS -NodeName $Fqdn -PsCommand $StressPayload
        $out = ($res.Output | Out-String).Trim()

        if ($res.ExitCode -eq 255) { Log "[$Fqdn] SSH connection failed.";                  return [pscustomobject]@{_s='err';Fqdn=$Fqdn} }
        if ($res.ExitCode -ne 0)   { Log "[$Fqdn] Remote failed (exit $($res.ExitCode)).";  return [pscustomobject]@{_s='err';Fqdn=$Fqdn} }

        try   { $obj = $out | ConvertFrom-Json }
        catch { Log "[$Fqdn] No JSON in output.`n$out";                                      return [pscustomobject]@{_s='err';Fqdn=$Fqdn} }

        if ($obj.Status -eq 'busy') { Log "[$Fqdn] Busy (task running)."; return [pscustomobject]@{_s='busy';Fqdn=$Fqdn} }

        if ($PoolMode -and $PoolName) { $obj | Add-Member -NotePropertyName Pool -NotePropertyValue $PoolName -Force }

        Log ("[$Fqdn] Done  Ev37={0}  CPU_Avg={1}%  Perf_Min={2}%  Perf_Avg={3}%  Perf_Max={4}%  Ev55_Worst={5}%  P95_Started={6}  P95_RanFull={7}  ActSec={8}" -f
            $obj.Ev37,$obj.CPU_AvgPct,$obj.Perf_MinPct,$obj.Perf_AvgPct,$obj.Perf_MaxPct,$obj.Ev55_Worst,$obj.P95_Started,$obj.P95_RanFull,$obj.ActSec)
        if ($obj.P95_Results) { Log "[$Fqdn] P95: $($obj.P95_Results)" }
        return $obj
    }

    function Drain-Queue {
        $msg = $null
        while ($msgQueue.TryDequeue([ref]$msg)) { Write-Host $msg; $msg = $null }
    }

    # Process in discrete batches — all nodes in a batch run concurrently,
    # and the next batch does not start until every node in the current batch completes.
    $totalBatches = [math]::Ceiling($Fqdns.Count / $max_parallel)
    $batchNum     = 0

    for ($i = 0; $i -lt $Fqdns.Count; $i += $max_parallel) {
        $batchNum++
        $batch = $Fqdns[$i..[math]::Min($i + $max_parallel - 1, $Fqdns.Count - 1)]

        Write-Host ""
        Write-Host ("  -- Batch {0}/{1}  ({2} node(s)) --" -f $batchNum, $totalBatches, $batch.Count)

        $jobs = [System.Collections.Generic.List[object]]::new()
        foreach ($fqdn in $batch) {
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $rsPool
            [void]$ps.AddScript($rsScript)
            [void]$ps.AddParameters(@{
                Fqdn          = $fqdn
                StressPayload = $stressPayload
                DurationSecs  = $duration_secs
                DryRun        = [bool]$dry_run
                PoolMode      = [bool]$pool
                PoolName      = $pool_name
                SshUser       = $ssh_user
                MsgQueue      = $msgQueue
            })
            $jobs.Add([pscustomobject]@{ PS=$ps; Handle=$ps.BeginInvoke(); Fqdn=$fqdn })
        }

        # Wait for every job in this batch before starting the next
        $pending       = [System.Collections.Generic.List[object]]::new($jobs)
        $lastHeartbeat = [datetime]::Now
        while ($pending.Count -gt 0) {
            Drain-Queue
            if (([datetime]::Now - $lastHeartbeat).TotalSeconds -ge 30) {
                Write-Host ("  [waiting] Batch {0}/{1}: {2} node(s) still running..." -f $batchNum, $totalBatches, $pending.Count)
                $lastHeartbeat = [datetime]::Now
            }
            $done = @($pending | Where-Object { $_.Handle.IsCompleted })
            foreach ($job in $done) {
                [void]$pending.Remove($job)
                try   { $r = $job.PS.EndInvoke($job.Handle)[0] }
                catch { $msgQueue.Enqueue("[$($job.Fqdn)] Runspace error: $_"); $r = [pscustomobject]@{_s='err';Fqdn=$job.Fqdn} }
                $job.PS.Dispose()

                $rs = if ($r -and $r.PSObject.Properties['_s']) { $r._s } else { $null }
                if     ($null -eq $r -or $rs -eq 'dry')  { }
                elseif ($rs -eq 'err')                    { if ($script:failed_ssh -notcontains $job.Fqdn) { $script:failed_ssh  += $job.Fqdn } }
                elseif ($rs -eq 'busy')                   { if ($script:busy_nodes -notcontains $job.Fqdn) { $script:busy_nodes  += $job.Fqdn } }
                else {
                    $script:results += $r
                    if ($IsRetry -and $script:retry_recovered -notcontains $job.Fqdn) { $script:retry_recovered += $job.Fqdn }
                }
            }
            if ($pending.Count -gt 0) { Start-Sleep -Milliseconds 250 }
        }
        Drain-Queue
    }

    $rsPool.Close()
    $rsPool.Dispose()
}

# ------------------ PASS 1 ------------------
Write-Host ""
Write-Host "------------------------------------------------------------"
Write-Host "         PASS 1 (STRESS + MEASURE THROTTLING)              "
Write-Host ("   Duration: {0}s   Nodes: {1}   Parallel: {2}   Dry run: {3}" -f $duration_secs, $targets.Count, $(if ($parallel) { "$max_parallel per batch" } else { "off" }), $dry_run)
Write-Host "------------------------------------------------------------"
Write-Host ""

if ($parallel) {
    Invoke-Parallel -Fqdns $targets
} else {
    foreach ($fqdn in $targets) {
        $result = Stress-Node -Fqdn $fqdn
        if     ($result -is [string] -and $result -eq 'busy') { if ($script:busy_nodes -notcontains $fqdn) { $script:busy_nodes += $fqdn } }
        elseif ($result)                                       { $script:results += $result }
    }
}

# ------------------ Busy retry loop ------------------
$busyPass = 0
while (-not $no_retry -and $script:busy_nodes.Count -gt 0) {
    $busyPass++
    $pending           = @($script:busy_nodes | Sort-Object -Unique)
    $script:busy_nodes = @()

    Sleep-BetweenPasses -Seconds $retry_sleep_secs -Label "busy retry $busyPass - $($pending.Count) node(s) running a task"
    Write-Host "---- BUSY RETRY $busyPass ($($pending.Count) node(s)) ----"
    Write-Host ""

    if ($parallel) {
        Invoke-Parallel -Fqdns $pending
    } else {
        foreach ($fqdn in $pending) {
            $result = Stress-Node -Fqdn $fqdn
            if     ($result -is [string] -and $result -eq 'busy') { $script:busy_nodes += $fqdn }
            elseif ($result)                                       { $script:results += $result }
        }
    }
}

# ------------------ SSH retry loop ------------------
$sshPass = 0
while (-not $no_retry -and $script:failed_ssh.Count -gt 0 -and $sshPass -lt $ssh_max_retries) {
    $sshPass++
    $retry             = @($script:failed_ssh | Sort-Object -Unique)
    $script:failed_ssh = @()

    Sleep-BetweenPasses -Seconds $retry_sleep_secs -Label "SSH retry $sshPass of $ssh_max_retries - $($retry.Count) node(s)"
    Write-Host "---- SSH RETRY $sshPass of $ssh_max_retries ($($retry.Count) node(s)) ----"
    Write-Host ""

    if ($parallel) {
        Invoke-Parallel -Fqdns $retry -IsRetry
    } else {
        foreach ($fqdn in $retry) {
            $result = Stress-Node -Fqdn $fqdn
            if     ($result -is [string] -and $result -eq 'busy') { if ($script:busy_nodes -notcontains $fqdn) { $script:busy_nodes += $fqdn } }
            elseif ($result) {
                $script:results += $result
                if ($script:retry_recovered -notcontains $fqdn) { $script:retry_recovered += $fqdn }
            }
        }
    }

    # Drain any busy nodes that surfaced during this SSH retry round
    while ($script:busy_nodes.Count -gt 0) {
        $busyPass++
        $pending           = @($script:busy_nodes | Sort-Object -Unique)
        $script:busy_nodes = @()
        Sleep-BetweenPasses -Seconds $retry_sleep_secs -Label "busy retry $busyPass (during SSH retry) - $($pending.Count) node(s)"
        foreach ($fqdn in $pending) {
            $result = Stress-Node -Fqdn $fqdn
            if     ($result -is [string] -and $result -eq 'busy') { $script:busy_nodes += $fqdn }
            elseif ($result) {
                $script:results += $result
                if ($script:retry_recovered -notcontains $fqdn) { $script:retry_recovered += $fqdn }
            }
        }
    }
}

# ------------------ CSV output ------------------
if ([string]::IsNullOrWhiteSpace($output_name)) {
    $output_name = "cpu_stress_{0}_{1}.csv" -f $script:tag, $script:stamp
}
$outCsv = Join-Path $output_dir $output_name

if ($dry_run) {
    Write-Host "DRY RUN: would write CSV to $outCsv"
} else {
    $okHosts = @($script:results | ForEach-Object { $_.Hostname }) | Sort-Object -Unique
    foreach ($fqdn in @($targets | Sort-Object -Unique)) {
        $short = $fqdn -replace ("\." + [regex]::Escape($domain_suffix) + "$"), ""
        if ($okHosts -notcontains $short -and $okHosts -notcontains $fqdn) {
            $script:results += [pscustomobject]@{
                Hostname  = $short
                Timestamp = (Get-Date).ToString("s")
                Error     = "No result after $ssh_max_retries SSH retries"
            }
        }
    }
    $script:results | Export-Csv -Path $outCsv -NoTypeInformation -Encoding UTF8
    Write-Host "CSV : $outCsv"
}

# ------------------ Summary ------------------
Write-Host ""
Write-Host "==== SUMMARY ===="
Write-Host ("Duration per node : {0}s" -f $duration_secs)
Write-Host ("Nodes targeted    : {0}"  -f $targets.Count)
Write-Host ""

$good = @($script:results | Where-Object { -not $_.PSObject.Properties['Error'] })
if ($good.Count -gt 0) {
    $good |
        Select-Object Hostname, ActSec, CPU_AvgPct, Perf_MinPct, Perf_AvgPct, Perf_MaxPct, Ev37, Ev55_Worst, Ev55_Avg, P95_Started, P95_RanFull |
        Sort-Object Ev37 -Descending |
        Format-Table -AutoSize |
        Out-String |
        Write-Host
}

Write-Host "Failed (after all retries):"
if (@($script:failed_ssh).Count -gt 0) { $script:failed_ssh | Sort-Object -Unique | ForEach-Object { Write-Host "  - $_" } }
else { Write-Host "  none" }

Write-Host ""
Write-Host "Recovered on retry:"
if (@($script:retry_recovered).Count -gt 0) { $script:retry_recovered | Sort-Object -Unique | ForEach-Object { Write-Host "  - $_" } }
else { Write-Host "  none" }

Write-Host ""
Write-Host "Log : $logFile"
Write-Host "CSV : $outCsv"

Stop-Transcript
