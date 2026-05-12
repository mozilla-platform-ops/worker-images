# UninstallFirefox.ps1
# Fleet-wide cleanup of Firefox installs that StressSP3.ps1 may have left behind.
#
# StressSP3.ps1's payload only installs Firefox via Chocolatey when firefox.exe
# is not already present, and only uninstalls it on the SAME run if that install
# succeeded. If a run was killed (SSH timeout, Ctrl-C, host reboot, etc.) before
# the uninstall step, Firefox can be left installed on the node. This script
# walks the fleet and uninstalls those.
#
# Default behavior is conservative: only uninstall Firefox if Chocolatey reports
# it as a managed package on the node ({{choco list --local-only firefox}}). If
# Firefox was installed manually or by an MSI image, choco won't know about it
# and we'll leave it alone. Pass -force to uninstall regardless.
#
# Per node:
#   - busy check (skip if generic-worker has a task running)
#   - kill any leftover firefox.exe and unregister our StressSP3_FF_* tasks
#   - check whether Chocolatey manages firefox
#   - choco uninstall firefox  (if managed, or if -force)
#   - verify firefox.exe is gone, report status
#
# Output: CSV at C:\logs\uninstall_firefox_<N>nodes_<stamp>.csv
#         JSON at the same path
#
# Same fleet-orchestration pattern as Scan-NUCHealth.ps1 / StressSP3-Fleet.ps1:
# range mode default 1..160, 18-node skip list, 3-pass SSH retry with 120s
# sleep, busy-skip-with-retry, parallel batches.
#
# Usage:
#   .\UninstallFirefox.ps1                                    # default sweep, conservative
#   .\UninstallFirefox.ps1 -dry_run                           # show what would happen
#   .\UninstallFirefox.ps1 -force                             # uninstall even if not choco-managed
#   .\UninstallFirefox.ps1 -nodes "nuc13-029,nuc13-077"       # subset
#   .\UninstallFirefox.ps1 -range_start 1 -range_end 50       # range subset
#   .\UninstallFirefox.ps1 -no_skip                           # disable skip list

param(
    [int]$range_start      = 1,
    [int]$range_end        = 160,
    [int]$range_pad        = 3,
    [string]$range_prefix  = "nuc13",
    [string]$nodes         = "",
    [switch]$single,
    [string]$node          = "",
    [string]$ssh_user      = "Administrator",
    [string]$domain_suffix = "wintest2.releng.mdc1.mozilla.com",
    [int]$max_parallel     = 8,
    [int]$ssh_max_retries  = 3,
    [int]$retry_sleep_secs = 120,
    [string]$output_dir    = "C:\logs",
    [switch]$no_skip,
    [switch]$dry_run,
    [switch]$force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ------------------ Skip list (consistent with other fleet scripts) ------------------
$skip_nodes = @(
    "nuc13-035","nuc13-036","nuc13-059","nuc13-060","nuc13-061",
    "nuc13-068","nuc13-070","nuc13-075","nuc13-096","nuc13-112",
    "nuc13-130","nuc13-149","nuc13-154","nuc13-155","nuc13-156","nuc13-157",
    "nuc13-107","nuc13-150"
)

# ------------------ Resolve target list ------------------
$target_shorts = @()
if ($single) {
    if (-not $node) { Write-Error "-node is required with -single"; exit 1 }
    $target_shorts = @(($node -replace '\..*$', '').Trim())
}
elseif ($nodes) {
    $target_shorts = @($nodes -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { ($_ -replace '\..*$', '').Trim() })
}
else {
    $target_shorts = $range_start..$range_end | ForEach-Object {
        "{0}-{1:D$range_pad}" -f $range_prefix, $_
    }
}

if (-not $no_skip -and -not $single) {
    $hit = @($target_shorts | Where-Object { $skip_nodes -contains $_ })
    $target_shorts = @($target_shorts | Where-Object { $skip_nodes -notcontains $_ })
    if ($hit.Count -gt 0) {
        Write-Host "Skipping $($hit.Count) known-problem node(s): $($hit -join ', ')" -ForegroundColor Yellow
    }
}

if ($target_shorts.Count -eq 0) { Write-Error "No nodes to scan."; exit 1 }
$targets = @($target_shorts | ForEach-Object { "$_.$domain_suffix" })

# ------------------ Output paths ------------------
$stamp   = (Get-Date).ToString('yyyyMMdd_HHmmss')
if (-not (Test-Path $output_dir)) { New-Item -ItemType Directory $output_dir -Force | Out-Null }
$logFile = Join-Path $output_dir ("uninstall_firefox_{0}nodes_{1}.log" -f $targets.Count, $stamp)
$csvFile = Join-Path $output_dir ("uninstall_firefox_{0}nodes_{1}.csv" -f $targets.Count, $stamp)
$jsonFile= Join-Path $output_dir ("uninstall_firefox_{0}nodes_{1}.json" -f $targets.Count, $stamp)
Start-Transcript -Path $logFile -Append | Out-Null

Write-Host ""
Write-Host "------------------------------------------------------------"
Write-Host "  UninstallFirefox fleet sweep"
Write-Host "  Targets    : $($targets.Count)"
Write-Host "  Parallel   : $max_parallel"
Write-Host "  Retries    : up to $ssh_max_retries SSH retry passes"
Write-Host "  Force      : $force"
Write-Host "  Dry-run    : $dry_run"
Write-Host "  CSV        : $csvFile"
Write-Host "------------------------------------------------------------"
Write-Host ""

# ------------------ Remote diagnostic + uninstall payload ------------------
$forceLiteral  = if ($force)  { '$true' } else { '$false' }
$dryRunLiteral = if ($dry_run){ '$true' } else { '$false' }

$diagPayload = @"
`$ErrorActionPreference = 'Continue'
`$forceUninstall = $forceLiteral
`$dryRun         = $dryRunLiteral

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

# --- Pre-cleanup: kill any leftover firefox + StressSP3 scheduled tasks ---
try { Get-Process firefox -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
try { Get-ScheduledTask -TaskName 'StressSP3_FF_*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:`$false -ErrorAction SilentlyContinue } catch {}
try { Remove-Item 'C:\Users\Public\sp3stress' -Recurse -Force -ErrorAction SilentlyContinue } catch {}
Start-Sleep -Seconds 1

# --- Detect Firefox install state ---
`$ffPaths = @(
    'C:\Program Files\Mozilla Firefox\firefox.exe',
    'C:\Program Files (x86)\Mozilla Firefox\firefox.exe'
)
`$ffExeBefore = `$ffPaths | Where-Object { Test-Path `$_ } | Select-Object -First 1
`$ffPresentBefore = `$null -ne `$ffExeBefore

# --- Detect Chocolatey-managed status ---
`$chocoExe = (Get-Command choco -ErrorAction SilentlyContinue).Source
`$chocoOk  = `$null -ne `$chocoExe
`$chocoListOut = ''
`$chocoManaged = `$false
if (`$chocoOk) {
    try {
        `$chocoListOut = (& choco list --local-only firefox -r 2>&1) -join "`n"
        if (`$chocoListOut -match '(?im)^firefox\|') { `$chocoManaged = `$true }
    } catch {}
    if (-not `$chocoManaged) {
        # older Choco versions: no -r, may print "Firefox v..." lines
        try {
            `$alt = (& choco list --local-only firefox 2>&1) -join "`n"
            if (`$alt -match '(?im)^firefox\s+\S+') { `$chocoManaged = `$true; `$chocoListOut = `$alt }
        } catch {}
    }
}

# --- Decide whether to uninstall ---
`$shouldUninstall = `$ffPresentBefore -and (`$chocoManaged -or `$forceUninstall)
`$action = if (`$dryRun) { 'dry_run' } elseif (-not `$ffPresentBefore) { 'absent' } elseif (-not `$chocoManaged -and -not `$forceUninstall) { 'skipped_not_choco_managed' } elseif (-not `$chocoOk) { 'skipped_no_choco' } else { 'uninstalling' }

`$chocoUninstallOut = ''
`$chocoUninstallExit = `$null
`$ffPresentAfter = `$ffPresentBefore
if (`$shouldUninstall -and -not `$dryRun -and `$chocoOk) {
    try {
        `$chocoUninstallOut = (& choco uninstall firefox --yes --no-progress --limit-output --remove-dependencies 2>&1) -join "`n"
        `$chocoUninstallExit = `$LASTEXITCODE
    } catch {
        `$chocoUninstallOut = `$_.Exception.Message
    }
    `$ffExeAfter = `$ffPaths | Where-Object { Test-Path `$_ } | Select-Object -First 1
    `$ffPresentAfter = `$null -ne `$ffExeAfter
    if (`$action -eq 'uninstalling') {
        `$action = if (-not `$ffPresentAfter -and `$chocoUninstallExit -eq 0) { 'uninstalled' } else { 'uninstall_failed' }
    }
}

[pscustomobject]@{
    Status           = 'ok'
    Hostname         = `$env:COMPUTERNAME
    Timestamp        = (Get-Date).ToString('s')
    FF_PresentBefore = `$ffPresentBefore
    FF_PathBefore    = `$ffExeBefore
    Choco_OK         = `$chocoOk
    Choco_Managed    = `$chocoManaged
    Choco_ListOut    = (`$chocoListOut -replace "`r`n",' ' | ForEach-Object { `$_.Substring(0,[math]::Min(400,`$_.Length)) })
    Action           = `$action
    Choco_Uninstall_Exit = `$chocoUninstallExit
    Choco_Uninstall_Out  = (`$chocoUninstallOut -replace "`r`n",' ' | ForEach-Object { `$_.Substring(0,[math]::Min(400,`$_.Length)) })
    FF_PresentAfter  = `$ffPresentAfter
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

    $remoteName = "uninstall_firefox_$([guid]::NewGuid().ToString('N')).ps1"
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

        Log "[$short] running uninstall"
        # Absolute home path so the same command works whether the SSH default shell is PowerShell or cmd.exe
        $remoteCmd = "powershell -NoLogo -NonInteractive -NoProfile -ExecutionPolicy Bypass -File C:\Users\Administrator\$remoteName"
        $sshArgs = "-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o UserKnownHostsFile=NUL -o StrictHostKeyChecking=no ${User}@${Fqdn} $remoteCmd"
        $psi2 = [System.Diagnostics.ProcessStartInfo]::new('ssh')
        $psi2.Arguments              = $sshArgs
        $psi2.UseShellExecute        = $false
        $psi2.RedirectStandardOutput = $true
        $psi2.RedirectStandardError  = $true
        $psi2.CreateNoWindow         = $true
        $sp2 = [System.Diagnostics.Process]::Start($psi2)
        $stdout = $sp2.StandardOutput.ReadToEnd()
        $stderr = $sp2.StandardError.ReadToEnd()
        # choco uninstall can take 60-180s; allow up to 5 min
        $exited2 = $sp2.WaitForExit(300000)
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

# ------------------ Parallel batch runner ------------------
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
                    'ok'     { "[$short] $($r.Data.Action)  before=$($r.Data.FF_PresentBefore)  managed=$($r.Data.Choco_Managed)  after=$($r.Data.FF_PresentAfter)" }
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

# ------------------ PASS 1 ------------------
Write-Host ""
Write-Host "==== PASS 1 ===="
$results = @{}
$pass1 = Invoke-ScanBatch -Fqdns $targets -Parallel $max_parallel
foreach ($k in $pass1.Keys) { $results[$k] = $pass1[$k] }

# ------------------ Busy retry pass ------------------
$busyPass = 0
while (-not $dry_run -and ($results.GetEnumerator() | Where-Object { $_.Value._s -eq 'busy' } | Measure-Object).Count -gt 0) {
    $busyPass++
    if ($busyPass -gt 3) { Write-Host "Busy retry cap (3) hit; remaining busy nodes will be reported as such."; break }
    $busyTargets = @($results.GetEnumerator() | Where-Object { $_.Value._s -eq 'busy' } | ForEach-Object { $_.Key })
    Write-Host ""
    Write-Host ("---- Sleeping {0}s : busy retry {1} - {2} node(s) ----" -f $retry_sleep_secs, $busyPass, $busyTargets.Count)
    Start-Sleep -Seconds $retry_sleep_secs
    $r = Invoke-ScanBatch -Fqdns $busyTargets -Parallel $max_parallel
    foreach ($k in $r.Keys) { $results[$k] = $r[$k] }
}

# ------------------ SSH retry passes ------------------
$pass = 1
while ($pass -le $ssh_max_retries) {
    $failed = @($results.GetEnumerator() | Where-Object { $_.Value._s -eq 'ssherr' } | ForEach-Object { $_.Key })
    if ($failed.Count -eq 0) { break }
    Write-Host ""
    Write-Host ("---- Sleeping {0}s : SSH retry {1} of {2} - {3} node(s) ----" -f $retry_sleep_secs, $pass, $ssh_max_retries, $failed.Count)
    Start-Sleep -Seconds $retry_sleep_secs
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
            Hostname           = $short
            Status             = 'ok'
            Action             = $d.Action
            FF_PresentBefore   = $d.FF_PresentBefore
            FF_PathBefore      = $d.FF_PathBefore
            Choco_Managed      = $d.Choco_Managed
            Choco_OK           = $d.Choco_OK
            Choco_ListOut      = $d.Choco_ListOut
            Choco_Uninstall_Exit = $d.Choco_Uninstall_Exit
            Choco_Uninstall_Out  = $d.Choco_Uninstall_Out
            FF_PresentAfter    = $d.FF_PresentAfter
            Timestamp          = $d.Timestamp
        }
    } elseif ($r._s -eq 'busy') {
        [pscustomobject]@{ Hostname=$short; Status='busy'; Action='busy_skipped'; FF_PresentBefore=''; FF_PathBefore=''; Choco_Managed=''; Choco_OK=''; Choco_ListOut=''; Choco_Uninstall_Exit=''; Choco_Uninstall_Out=''; FF_PresentAfter=''; Timestamp='' }
    } else {
        $reason = if ($r.PSObject.Properties.Name -contains 'Reason') { ($r.Reason -replace "`r`n",' ' -replace "\s+", ' ') } else { 'unknown' }
        [pscustomobject]@{ Hostname=$short; Status='ssh_failed'; Action='ssh_failed'; FF_PresentBefore=''; FF_PathBefore=''; Choco_Managed=''; Choco_OK=''; Choco_ListOut=$reason; Choco_Uninstall_Exit=''; Choco_Uninstall_Out=''; FF_PresentAfter=''; Timestamp='' }
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
Write-Host ("  Scanned         : {0}" -f $rows.Count)
Write-Host ("  Reached         : {0}" -f $ok.Count)
Write-Host ("  Busy (skipped)  : {0}" -f $busy.Count)
Write-Host ("  SSH failed      : {0}  (after $ssh_max_retries retries)" -f $failed.Count)
Write-Host ""

if ($ok.Count -gt 0) {
    $byAction = $ok | Group-Object Action | Sort-Object Count -Descending
    Write-Host "==== Actions on reached nodes ===="
    foreach ($g in $byAction) {
        Write-Host ("  {0,-30} : {1}" -f $g.Name, $g.Count)
    }
    Write-Host ""

    $stillPresent = @($ok | Where-Object { $_.FF_PresentAfter -eq $true -and $_.FF_PresentBefore -eq $true })
    if ($stillPresent.Count -gt 0) {
        Write-Host "==== Nodes where Firefox is still present after this run ===="
        foreach ($r in $stillPresent) {
            Write-Host ("  {0}  action={1}  managed={2}  exit={3}" -f $r.Hostname, $r.Action, $r.Choco_Managed, $r.Choco_Uninstall_Exit)
        }
        Write-Host ""
    }

    $absent = @($ok | Where-Object { $_.FF_PresentBefore -eq $false })
    Write-Host ("Nodes that already had no Firefox: {0}" -f $absent.Count)
    Write-Host ""
}

if ($busy.Count -gt 0) {
    Write-Host "==== BUSY (skipped) ===="
    $busy | ForEach-Object { Write-Host ("  {0}" -f $_.Hostname) }
}
if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "==== FAILED (after retries) ===="
    $failed | ForEach-Object { Write-Host ("  {0}  -- {1}" -f $_.Hostname, $_.Choco_ListOut) }
}

Write-Host ""
Write-Host "Log : $logFile"
Write-Host "CSV : $csvFile"
Write-Host "JSON: $jsonFile"
Stop-Transcript | Out-Null
