# Scan-NUCHealth.ps1
# Fleet-wide scan for the "reduced single-core turbo headroom" pattern that
# nuc13-029 exhibits (SP3 ~17% slower than healthy peers, brief CPU burner
# Perf_Max capped near 150% while healthy nodes hit 230%+).
#
# Per node:
#   - busy check (skip if generic-worker has a task running)
#   - 10-second single-thread CPU burner sampling % Processor Performance
#   - PerfPct min/avg/max + raw samples
#   - power plan, BIOS version/date, CPU base MHz, RAM total, OS build, uptime
#
# Retries: 3 sequential passes for any node that fails SSH. Failed nodes are
# retried only - successful nodes don't re-run.
#
# Output:
#   - CSV at C:\logs\fleet_scan_<N>nodes_<stamp>.csv (one row per node)
#   - Console summary: top suspects sorted by lowest Perf_Max
#
# Usage:
#   .\Scan-NUCHealth.ps1                                           # default 001-160 sweep
#   .\Scan-NUCHealth.ps1 -range_start 1 -range_end 50              # subset
#   .\Scan-NUCHealth.ps1 -nodes "nuc13-029,nuc13-066"              # explicit list
#   .\Scan-NUCHealth.ps1 -max_parallel 4                           # less aggressive parallelism
#   .\Scan-NUCHealth.ps1 -no_skip                                  # disable skip list

param(
    [int]$range_start      = 1,
    [int]$range_end        = 160,
    [int]$range_pad        = 3,
    [string]$range_prefix  = "nuc13",
    [string]$nodes         = "",
    [string]$ssh_user      = "Administrator",
    [string]$domain_suffix = "wintest2.releng.mdc1.mozilla.com",
    [int]$max_parallel     = 8,
    [int]$ssh_max_retries  = 3,
    [int]$retry_sleep_secs = 120,
    [int]$burner_secs      = 10,
    [int]$top_suspects     = 30,
    [string]$output_dir    = "C:\logs",
    [switch]$no_skip,
    [switch]$dry_run
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ------------------ Skip list (consistent with StressCPU) ------------------
$skip_nodes = @(
    "nuc13-035","nuc13-036","nuc13-059","nuc13-060","nuc13-061",
    "nuc13-068","nuc13-070","nuc13-075","nuc13-096","nuc13-112",
    "nuc13-130","nuc13-149","nuc13-154","nuc13-155","nuc13-156","nuc13-157",
    "nuc13-107","nuc13-150"
)

# ------------------ Resolve target list ------------------
$target_shorts = @()
if ($nodes) {
    $target_shorts = @($nodes -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { ($_ -replace '\..*$', '').Trim() })
} else {
    $target_shorts = $range_start..$range_end | ForEach-Object {
        "{0}-{1:D$range_pad}" -f $range_prefix, $_
    }
}

if (-not $no_skip) {
    $before = $target_shorts.Count
    $target_shorts = @($target_shorts | Where-Object { $skip_nodes -notcontains $_ })
    $skipped = $before - $target_shorts.Count
    if ($skipped -gt 0) {
        Write-Host "Skipping $skipped known-problem node(s)." -ForegroundColor Yellow
    }
}

if ($target_shorts.Count -eq 0) { Write-Error "No nodes to scan."; exit 1 }

$targets = @($target_shorts | ForEach-Object { "$_.$domain_suffix" })

# ------------------ Output paths ------------------
$stamp   = (Get-Date).ToString('yyyyMMdd_HHmmss')
if (-not (Test-Path $output_dir)) { New-Item -ItemType Directory $output_dir -Force | Out-Null }
$logFile = Join-Path $output_dir ("fleet_scan_{0}nodes_{1}.log" -f $targets.Count, $stamp)
$csvFile = Join-Path $output_dir ("fleet_scan_{0}nodes_{1}.csv" -f $targets.Count, $stamp)
$jsonFile= Join-Path $output_dir ("fleet_scan_{0}nodes_{1}.json" -f $targets.Count, $stamp)

Start-Transcript -Path $logFile -Append | Out-Null

Write-Host ""
Write-Host "------------------------------------------------------------"
Write-Host "  Scan-NUCHealth fleet sweep"
Write-Host "  Nodes      : $($targets.Count) (range $range_start..$range_end)"
Write-Host "  Parallel   : $max_parallel"
Write-Host "  Retries    : up to $ssh_max_retries SSH retry passes"
Write-Host "  Burner     : ${burner_secs}s per node"
Write-Host "  User       : $ssh_user"
Write-Host "  Skip list  : $(if ($no_skip) { 'disabled' } else { "$($skip_nodes.Count) nodes" })"
Write-Host "  CSV        : $csvFile"
Write-Host "------------------------------------------------------------"
Write-Host ""

# ------------------ Remote diagnostic payload ------------------
$diagPayload = @"
`$ErrorActionPreference = 'Continue'

# --- Busy check (skip if generic-worker has a task) ---
`$wsp = `$null
foreach (`$p in @("C:\WINDOWS\SystemTemp", `$env:TMP, `$env:TEMP, `$env:USERPROFILE)) {
    if (`$p) { `$c = Join-Path `$p "worker-status.json"; if (Test-Path `$c) { `$wsp = `$c; break } }
}
`$busy = `$false
if (`$wsp) {
    try { `$j = Get-Content `$wsp -Raw | ConvertFrom-Json; if (@(`$j.currentTaskIds).Count -gt 0) { `$busy = `$true } } catch {}
}
if (`$busy) {
    [pscustomobject]@{ Status='busy'; Hostname=`$env:COMPUTERNAME } | ConvertTo-Json -Compress
    return
}

# --- Power plan + min/max state ---
`$pwrSchemeOut = & powercfg /getactivescheme 2>`$null
`$pwrPlan = if (`$pwrSchemeOut -match 'GUID:\s+[a-f0-9-]+\s+\((.+)\)') { `$matches[1] } else { 'unknown' }

# --- CPU info ---
`$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
`$cpuName = `$cpu.Name
`$cpuMaxMHz = `$cpu.MaxClockSpeed

# --- Achieved %Performance under brief load ---
# Use an inline runspace (not Start-Job) for the CPU burner: Start-Job spawns a
# whole child powershell.exe which can take 5-15s to initialize on a cold-cache
# node. Runspaces start in <100ms.
`$burnerSecs = $burner_secs
`$perfSamples = @()
`$burnerRunspace = [runspacefactory]::CreateRunspace()
`$burnerRunspace.Open()
`$burnerPS = [powershell]::Create()
`$burnerPS.Runspace = `$burnerRunspace
[void]`$burnerPS.AddScript({
    param(`$secs)
    `$end = (Get-Date).AddSeconds(`$secs + 1)
    while ((Get-Date) -lt `$end) { `$x = 0; for (`$i=0; `$i -lt 1000000; `$i++) { `$x = `$x + `$i } }
}).AddArgument(`$burnerSecs)
`$burnerHandle = `$burnerPS.BeginInvoke()
Start-Sleep -Milliseconds 300
for (`$s = 0; `$s -lt `$burnerSecs; `$s++) {
    try {
        `$ctr = (Get-Counter '\Processor Information(_Total)\% Processor Performance' -ErrorAction Stop).CounterSamples[0].CookedValue
        `$perfSamples += [math]::Round(`$ctr, 1)
    } catch {}
    Start-Sleep -Milliseconds 900
}
try { `$burnerPS.Stop() } catch {}
try { `$burnerPS.Dispose() } catch {}
try { `$burnerRunspace.Close(); `$burnerRunspace.Dispose() } catch {}

`$perfMax = if (`$perfSamples.Count -gt 0) { (`$perfSamples | Measure-Object -Maximum).Maximum } else { `$null }
`$perfMin = if (`$perfSamples.Count -gt 0) { (`$perfSamples | Measure-Object -Minimum).Minimum } else { `$null }
`$perfAvg = if (`$perfSamples.Count -gt 0) { [math]::Round((`$perfSamples | Measure-Object -Average).Average, 1) } else { `$null }
# Late-window samples (after the CPU has warmed) - exposes thermal/PSU collapse
`$lateSamples = @()
if (`$perfSamples.Count -ge 4) { `$lateSamples = `$perfSamples[(`$perfSamples.Count - 4)..(`$perfSamples.Count - 1)] }
`$perfLateAvg = if (`$lateSamples.Count -gt 0) { [math]::Round((`$lateSamples | Measure-Object -Average).Average, 1) } else { `$null }
`$perfLateMin = if (`$lateSamples.Count -gt 0) { (`$lateSamples | Measure-Object -Minimum).Minimum } else { `$null }

# --- RAM ---
`$ramDimms = @(Get-CimInstance Win32_PhysicalMemory)
`$ramTotalGB = [math]::Round((`$ramDimms | Measure-Object -Property Capacity -Sum).Sum / 1GB, 1)
`$ramSpeed = (`$ramDimms | ForEach-Object { `$_.ConfiguredClockSpeed } | Sort-Object -Unique) -join '/'

# --- BIOS ---
`$bios = Get-CimInstance Win32_BIOS
`$biosVer = `$bios.SMBIOSBIOSVersion
`$biosDate = if (`$bios.ReleaseDate) { (`$bios.ReleaseDate).ToString('yyyy-MM-dd') } else { '?' }

# --- OS / uptime ---
`$os = Get-CimInstance Win32_OperatingSystem
`$osBuild = `$os.BuildNumber
`$uptimeMin = [int]((Get-Date) - `$os.LastBootUpTime).TotalMinutes

[pscustomobject]@{
    Status        = 'ok'
    Hostname      = `$env:COMPUTERNAME
    Timestamp     = (Get-Date).ToString('s')
    PowerPlan     = `$pwrPlan
    CPU           = `$cpuName
    CPU_MaxMHz    = `$cpuMaxMHz
    Perf_Max      = `$perfMax
    Perf_Avg      = `$perfAvg
    Perf_Min      = `$perfMin
    Perf_LateAvg  = `$perfLateAvg
    Perf_LateMin  = `$perfLateMin
    Perf_Samples  = `$perfSamples -join ','
    RAM_GB        = `$ramTotalGB
    RAM_MHz       = `$ramSpeed
    BIOS_Version  = `$biosVer
    BIOS_Date     = `$biosDate
    OS_Build      = `$osBuild
    Uptime_Min    = `$uptimeMin
} | ConvertTo-Json -Depth 5 -Compress
"@

# ------------------ Per-node helper (scp + ssh -File) ------------------
$rsScript = {
    param(
        [string]$Fqdn,
        [string]$User,
        [string]$Payload,
        [System.Collections.Concurrent.ConcurrentQueue[string]]$MsgQueue
    )

    function Log { param([string]$Msg) $MsgQueue.Enqueue($Msg) }
    $short = ($Fqdn -split '\.')[0]
    Log "[$short] start"

    $remoteName = "scan_nuchealth_$([guid]::NewGuid().ToString('N')).ps1"
    $localTemp  = Join-Path $env:TEMP $remoteName
    Set-Content -Path $localTemp -Value $Payload -Encoding UTF8

    try {
        $scpArgs = "-O -o ConnectTimeout=10 -o UserKnownHostsFile=NUL -o StrictHostKeyChecking=no `"$localTemp`" `"${User}@${Fqdn}:$remoteName`""
        $psi = [System.Diagnostics.ProcessStartInfo]::new('scp')
        $psi.Arguments              = $scpArgs
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true
        $sp = [System.Diagnostics.Process]::Start($psi)
        $sp.StandardOutput.ReadToEnd() | Out-Null
        $scpErr = $sp.StandardError.ReadToEnd()
        $exited = $sp.WaitForExit(25000)
        if (-not $exited) { try { $sp.Kill() } catch {}; return [pscustomobject]@{ _s='ssherr'; Fqdn=$Fqdn; Reason="scp timeout" } }
        $scpExit = $sp.ExitCode
        $sp.Dispose()
        if ($scpExit -ne 0) {
            return [pscustomobject]@{ _s='ssherr'; Fqdn=$Fqdn; Reason="scp exit $scpExit : $scpErr" }
        }

        Log "[$short] running diag"
        # Use absolute Administrator home path (no $env or %% expansion needed) so the
        # command parses identically whether the remote default shell is PowerShell
        # or cmd.exe. Drop the trailing "; Remove-Item ..." (which CRT argv parsing
        # would concatenate onto the path arg as a literal ";") - we accept the
        # leftover ~2KB scan_nuchealth_*.ps1 in C:\Users\Administrator\ for now;
        # CleanupSP3.ps1 covers stress_payload_*.ps1 and a similar sweep can clean
        # these scan files later if needed.
        $remoteCmd = "powershell -NoLogo -NonInteractive -NoProfile -ExecutionPolicy Bypass -File C:\Users\Administrator\$remoteName"
        $sshArgs = "-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o UserKnownHostsFile=NUL -o StrictHostKeyChecking=no ${User}@${Fqdn} $remoteCmd"
        $psi2 = [System.Diagnostics.ProcessStartInfo]::new('ssh')
        $psi2.Arguments              = $sshArgs
        $psi2.UseShellExecute        = $false
        $psi2.RedirectStandardOutput = $true
        $psi2.RedirectStandardError  = $true
        $psi2.CreateNoWindow         = $true
        $sp2 = [System.Diagnostics.Process]::Start($psi2)
        $stdout = $sp2.StandardOutput.ReadToEnd()
        $stderr = $sp2.StandardError.ReadToEnd()
        $exited2 = $sp2.WaitForExit(60000)
        if (-not $exited2) { try { $sp2.Kill() } catch {}; return [pscustomobject]@{ _s='ssherr'; Fqdn=$Fqdn; Reason="ssh timeout" } }
        $sshExit = $sp2.ExitCode
        $sp2.Dispose()
        if ($sshExit -ne 0) {
            return [pscustomobject]@{ _s='ssherr'; Fqdn=$Fqdn; Reason="ssh exit $sshExit : $stderr" }
        }

        $jsonLine = ($stdout -split "`n") | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1
        if (-not $jsonLine) {
            return [pscustomobject]@{ _s='ssherr'; Fqdn=$Fqdn; Reason="no JSON in stdout" }
        }
        try {
            $obj = $jsonLine | ConvertFrom-Json
        } catch {
            return [pscustomobject]@{ _s='ssherr'; Fqdn=$Fqdn; Reason="JSON parse: $_" }
        }

        if ($obj.Status -eq 'busy') {
            return [pscustomobject]@{ _s='busy'; Fqdn=$Fqdn; Hostname=$obj.Hostname }
        }

        return [pscustomobject]@{ _s='ok'; Fqdn=$Fqdn; Data=$obj }
    } finally {
        Remove-Item $localTemp -Force -ErrorAction SilentlyContinue
    }
}

# ------------------ Parallel runner ------------------
function Invoke-ScanBatch {
    param([string[]]$Fqdns, [int]$Parallel)

    $rsPool = [RunspaceFactory]::CreateRunspacePool(1, [math]::Max(1, $Parallel))
    $rsPool.Open()
    $msgQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

    function Drain-Queue {
        $msg = $null
        while ($msgQueue.TryDequeue([ref]$msg)) { Write-Host $msg; $msg = $null }
    }

    $totalBatches = [math]::Ceiling($Fqdns.Count / $Parallel)
    $batchNum = 0
    $batchResults = @{}

    for ($i = 0; $i -lt $Fqdns.Count; $i += $Parallel) {
        $batchNum++
        $batch = $Fqdns[$i..[math]::Min($i + $Parallel - 1, $Fqdns.Count - 1)]
        Write-Host ("  Batch {0}/{1} : {2} node(s)" -f $batchNum, $totalBatches, $batch.Count)

        $jobs = [System.Collections.Generic.List[object]]::new()
        foreach ($fqdn in $batch) {
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $rsPool
            [void]$ps.AddScript($rsScript)
            [void]$ps.AddParameters(@{ Fqdn=$fqdn; User=$ssh_user; Payload=$diagPayload; MsgQueue=$msgQueue })
            $jobs.Add([pscustomobject]@{ PS=$ps; Handle=$ps.BeginInvoke(); Fqdn=$fqdn })
        }

        $pending = [System.Collections.Generic.List[object]]::new($jobs)
        $lastHB = [datetime]::Now
        while ($pending.Count -gt 0) {
            Drain-Queue
            if (([datetime]::Now - $lastHB).TotalSeconds -ge 30) {
                Write-Host ("    [waiting] {0} node(s) still in this batch..." -f $pending.Count)
                $lastHB = [datetime]::Now
            }
            $done = @($pending | Where-Object { $_.Handle.IsCompleted })
            foreach ($job in $done) {
                [void]$pending.Remove($job)
                try { $r = $job.PS.EndInvoke($job.Handle)[0] }
                catch { $r = [pscustomobject]@{ _s='ssherr'; Fqdn=$job.Fqdn; Reason="runspace error: $_" } }
                $job.PS.Dispose()
                $batchResults[$job.Fqdn] = $r
                $short = ($job.Fqdn -split '\.')[0]
                $msg = switch ($r._s) {
                    'ok'     { "[$short] ok  Perf_Max=$($r.Data.Perf_Max)  Perf_LateAvg=$($r.Data.Perf_LateAvg)" }
                    'busy'   { "[$short] busy (skipped)" }
                    'ssherr' { "[$short] SSH/diag failed: $($r.Reason)" }
                    default  { "[$short] unknown state" }
                }
                Write-Host $msg
            }
            if ($pending.Count -gt 0) { Start-Sleep -Milliseconds 250 }
        }
        Drain-Queue
    }

    $rsPool.Close()
    $rsPool.Dispose()
    return $batchResults
}

if ($dry_run) {
    Write-Host "DRY RUN: would scan $($targets.Count) node(s)."
    $target_shorts | ForEach-Object { Write-Host "  $_" }
    Stop-Transcript | Out-Null
    return
}

# ------------------ PASS 1 ------------------
Write-Host ""
Write-Host "==== PASS 1 ===="
$results = @{}
$pass1 = Invoke-ScanBatch -Fqdns $targets -Parallel $max_parallel
foreach ($k in $pass1.Keys) { $results[$k] = $pass1[$k] }

# ------------------ Retry passes ------------------
$pass = 1
while ($pass -le $ssh_max_retries) {
    $failed = @($results.GetEnumerator() | Where-Object { $_.Value._s -eq 'ssherr' } | ForEach-Object { $_.Key })
    if ($failed.Count -eq 0) { break }
    Write-Host ""
    Write-Host ("---- Sleeping {0}s : SSH retry {1} of {2} - {3} node(s) ----" -f $retry_sleep_secs, $pass, $ssh_max_retries, $failed.Count)
    Start-Sleep -Seconds $retry_sleep_secs
    Write-Host ""
    Write-Host ("==== RETRY PASS {0} ({1} node(s)) ====" -f $pass, $failed.Count)
    $r = Invoke-ScanBatch -Fqdns $failed -Parallel $max_parallel
    foreach ($k in $r.Keys) { $results[$k] = $r[$k] }
    $pass++
}

# ------------------ Build CSV rows ------------------
$rows = foreach ($fqdn in $targets) {
    $short = ($fqdn -split '\.')[0]
    $r = if ($results.ContainsKey($fqdn)) { $results[$fqdn] } else { [pscustomobject]@{ _s='ssherr'; Reason='not attempted' } }
    if ($r._s -eq 'ok' -and $r.Data) {
        $d = $r.Data
        [pscustomobject]@{
            Hostname     = $short
            Status       = 'ok'
            Perf_Max     = $d.Perf_Max
            Perf_Avg     = $d.Perf_Avg
            Perf_Min     = $d.Perf_Min
            Perf_LateAvg = $d.Perf_LateAvg
            Perf_LateMin = $d.Perf_LateMin
            Perf_Samples = $d.Perf_Samples
            CPU_MaxMHz   = $d.CPU_MaxMHz
            PowerPlan    = $d.PowerPlan
            RAM_GB       = $d.RAM_GB
            RAM_MHz      = $d.RAM_MHz
            BIOS_Version = $d.BIOS_Version
            BIOS_Date    = $d.BIOS_Date
            OS_Build     = $d.OS_Build
            Uptime_Min   = $d.Uptime_Min
            Timestamp    = $d.Timestamp
            Note         = ''
        }
    } elseif ($r._s -eq 'busy') {
        [pscustomobject]@{ Hostname=$short; Status='busy'; Note='worker had a task' }
    } else {
        [pscustomobject]@{ Hostname=$short; Status='ssh_failed'; Note=($r.Reason -replace "`r`n",' ' -replace "\s+", ' ') }
    }
}

$rows | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8
$results | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonFile -Encoding UTF8

# ------------------ Summary ------------------
$ok      = @($rows | Where-Object { $_.Status -eq 'ok' })
$busy    = @($rows | Where-Object { $_.Status -eq 'busy' })
$failed  = @($rows | Where-Object { $_.Status -eq 'ssh_failed' })

Write-Host ""
Write-Host "============================================================"
Write-Host "  SUMMARY"
Write-Host "============================================================"
Write-Host ("  Scanned       : {0}" -f $rows.Count)
Write-Host ("  Successful    : {0}" -f $ok.Count)
Write-Host ("  Busy (skip)   : {0}" -f $busy.Count)
Write-Host ("  Failed (ssh)  : {0}  (after $ssh_max_retries retries)" -f $failed.Count)
Write-Host ""

if ($ok.Count -gt 0) {
    Write-Host "==== TOP $top_suspects SUSPECTS (lowest Perf_Max - possible reduced turbo headroom) ===="
    $ok |
        Sort-Object @{e={[double]$_.Perf_Max}; ascending=$true} |
        Select-Object -First $top_suspects |
        Format-Table Hostname, Perf_Max, Perf_Avg, Perf_Min, Perf_LateAvg, Perf_LateMin, BIOS_Version, BIOS_Date, Uptime_Min -AutoSize |
        Out-String | Write-Host

    $maxAll = ($ok | ForEach-Object { [double]$_.Perf_Max } | Measure-Object -Maximum).Maximum
    $avgAll = [math]::Round(($ok | ForEach-Object { [double]$_.Perf_Max } | Measure-Object -Average).Average, 1)
    $minAll = ($ok | ForEach-Object { [double]$_.Perf_Max } | Measure-Object -Minimum).Minimum
    Write-Host ("Fleet Perf_Max  min={0}  avg={1}  max={2}" -f $minAll, $avgAll, $maxAll)
}

if ($busy.Count -gt 0) {
    Write-Host ""
    Write-Host "==== BUSY (skipped) ===="
    $busy | ForEach-Object { Write-Host ("  {0}" -f $_.Hostname) }
}

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "==== FAILED (after retries) ===="
    $failed | ForEach-Object { Write-Host ("  {0}  -- {1}" -f $_.Hostname, $_.Note) }
}

Write-Host ""
Write-Host "Log : $logFile"
Write-Host "CSV : $csvFile"
Write-Host "JSON: $jsonFile"
Stop-Transcript | Out-Null
