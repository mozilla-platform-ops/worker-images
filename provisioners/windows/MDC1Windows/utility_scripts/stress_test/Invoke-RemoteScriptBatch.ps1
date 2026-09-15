function Invoke-RemoteScriptBatch {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'MsgQueue', Justification = 'Consumed by the nested runspace Log helper.')]
    param (
        [string[]] $Fqdns,
        [ValidateRange(1, 2147483647)][int] $Parallel,
        [string] $User,
        [string] $Payload,
        [ValidatePattern('^[a-z_]+$')][string] $NamePrefix,
        [ValidateRange(1, 2147483647)][int] $TimeoutMs,
        [int] $ServerAliveCountMax = 3,
        [scriptblock] $DescribeResult
    )

    $rsScript = {
        param(
            [string]$Fqdn,
            [string]$User,
            [string]$Payload,
            [System.Collections.Concurrent.ConcurrentQueue[string]]$MsgQueue,
            [string]$NamePrefix,
            [int]$TimeoutMs,
            [int]$ServerAliveCountMax
        )

        function Log { param([string]$Msg) $MsgQueue.Enqueue($Msg) }
        $short = ($Fqdn -split '\.')[0]
        Log "[$short] start"

        $remoteName = "${NamePrefix}_$([guid]::NewGuid().ToString('N')).ps1"
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
            if (-not $exited) { try { $sp.Kill() } catch { Write-Verbose "Process cleanup failed: $_" }; return [pscustomobject]@{ _s='ssherr'; Fqdn=$Fqdn; Reason="scp timeout" } }
            $scpExit = $sp.ExitCode
            $sp.Dispose()
            if ($scpExit -ne 0) {
                return [pscustomobject]@{ _s='ssherr'; Fqdn=$Fqdn; Reason="scp exit $scpExit : $scpErr" }
            }

            Log "[$short] running $NamePrefix"
            # Absolute home path works with either cmd.exe or PowerShell as the SSH shell.
            $remoteCmd = "powershell -NoLogo -NonInteractive -NoProfile -ExecutionPolicy Bypass -File C:\Users\Administrator\$remoteName"
            $sshArgs = "-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=$ServerAliveCountMax -o UserKnownHostsFile=NUL -o StrictHostKeyChecking=no ${User}@${Fqdn} $remoteCmd"
            $psi2 = [System.Diagnostics.ProcessStartInfo]::new('ssh')
            $psi2.Arguments              = $sshArgs
            $psi2.UseShellExecute        = $false
            $psi2.RedirectStandardOutput = $true
            $psi2.RedirectStandardError  = $true
            $psi2.CreateNoWindow         = $true
            $sp2 = [System.Diagnostics.Process]::Start($psi2)
            $stdout = $sp2.StandardOutput.ReadToEnd()
            $stderr = $sp2.StandardError.ReadToEnd()
            $exited2 = $sp2.WaitForExit($TimeoutMs)
            if (-not $exited2) { try { $sp2.Kill() } catch { Write-Verbose "Process cleanup failed: $_" }; return [pscustomobject]@{ _s='ssherr'; Fqdn=$Fqdn; Reason="ssh timeout" } }
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
            [void]$ps.AddParameters(@{ Fqdn=$fqdn; User=$User; Payload=$Payload; MsgQueue=$msgQueue; NamePrefix=$NamePrefix; TimeoutMs=$TimeoutMs; ServerAliveCountMax=$ServerAliveCountMax })
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
                    'ok'     { & $DescribeResult $short $r.Data }
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
