# StressSP3.ps1
# SSH-driven Speedometer 3.1 replication harness for the wintest2 NUC13 fleet,
# built for RELOPS-2323 throttling investigation 2026-05-07.
#
# Per node, the harness:
#   - logs in as Administrator via scp+ssh -File transport (avoids the cmd.exe
#     8191-char limit that silently truncates -EncodedCommand on this fleet)
#   - detects the active interactive task user via `query user`
#   - launches Firefox in the task user's session via a one-shot scheduled task
#     with -LogonType Interactive (no password needed - uses the user's logon
#     token), so the workload runs in the same context Mozilla CI uses
#   - drives Speedometer 3.1 via Marionette over TCP 2828 (custom Python client)
#   - loops the SP3 run -sp3_loops times in the same Firefox to approximate
#     CI's ~10-min Browsertime cycle window
#   - captures Microsoft-Windows-Kernel-Processor-Power ETW events Ev37/48/51/55/58
#     and CPU sampling alongside the workload
#   - returns per-loop scores plus throttling counters as JSON
#
# Modes:
#   -single -node nuc13-XXX           one node
#   -nodes "n1,n2,n3"                 explicit list (parallel by default)
#   default                           20-node May 2026 perf-anomaly list
#   -test_remote                      pipeline smoke test with a tiny payload
#   -visible                          drop --headless so Firefox shows on the desktop
#   -sp3_loops N                      number of SP3 cycles per node (default 1)
#   -sp3_iterations N                 SP3 internal iteration count (default 10)
#   -duration_secs N                  per-node safety cap on the sample loop
#
# Output: CSV + transcript log in C:\logs.

param(
    [int]$duration_secs    = 600,
    [int]$retry_sleep_secs = 120,
    [int]$ssh_max_retries  = 3,
    [int]$max_parallel     = 3,
    [string]$output_dir    = "C:\logs",
    [switch]$quick,
    [switch]$dry_run,
    [switch]$no_retry,
    [switch]$single,
    [string]$node          = "",
    [switch]$test_remote,
    [string]$ssh_user      = "Administrator",
    [switch]$visible,
    [int]$sp3_iterations   = 10,
    [int]$sp3_loops        = 1,
    [string]$nodes         = ""
)

# -quick: 420s cap — enough to let one SP3 run actually finish (~5-7 min) so we can
# validate the score-element detection and ETW capture end-to-end on a single node.
# For pipeline-only smoke tests (no full SP3 run), use -test_remote instead.
if ($quick) { $duration_secs = 420; $retry_sleep_secs = 10 }

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:stamp           = (Get-Date).ToString("yyyyMMdd_HHmmss")
$script:failed_ssh      = @()
$script:retry_recovered = @()
$script:busy_nodes      = @()
$script:results         = @()

$domain_suffix    = "wintest2.releng.mdc1.mozilla.com"
$ssh_timeout_secs = $duration_secs + 600   # choco install/uninstall + FF startup + SP3 run + ETW analysis

$target_shorts = @(
    "nuc13-029","nuc13-137","nuc13-028","nuc13-051","nuc13-025",
    "nuc13-043","nuc13-143","nuc13-062","nuc13-138","nuc13-134",
    "nuc13-039","nuc13-092","nuc13-076","nuc13-042","nuc13-140",
    "nuc13-119","nuc13-116","nuc13-030","nuc13-074","nuc13-071"
)
if ($nodes) {
    $target_shorts = @($nodes -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { ($_ -replace '\..*$', '').Trim() })
}
if ($single) {
    if (-not $node) { Write-Error "-node is required with -single"; exit 1 }
    $target_shorts = @($node -replace '\..*$', '')
}
$targets = @($target_shorts | ForEach-Object { "$_.$domain_suffix" })

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
    param([Parameter(Mandatory)][string]$NodeName, [Parameter(Mandatory)][string]$Command,
          [int]$TimeoutSec = 600, [string]$StdinText = "")
    $target = if ($NodeName -match '@') { $NodeName } else { "$ssh_user@$NodeName" }
    $psi = [System.Diagnostics.ProcessStartInfo]::new('ssh')
    $psi.Arguments              = "-o ConnectTimeout=15 -o UserKnownHostsFile=NUL -o StrictHostKeyChecking=no $target $Command"
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardInput  = $true
    $psi.CreateNoWindow         = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if ($StdinText) { $p.StandardInput.Write($StdinText) }
    $p.StandardInput.Close()
    $exited  = $p.WaitForExit($TimeoutSec * 1000)
    if (-not $exited) { try { $p.Kill() } catch {} }
    $null = $outTask.Wait(10000)
    $null = $errTask.Wait(10000)
    $stdout   = if ($outTask.Status -eq 'RanToCompletion') { $outTask.Result } else { '' }
    $stderr   = if ($errTask.Status -eq 'RanToCompletion') { $errTask.Result } else { '' }
    $exitCode = if ($exited) { $p.ExitCode } else { 255 }
    $p.Dispose()
    [pscustomobject]@{ Output = $stdout; Error = $stderr; ExitCode = $exitCode }
}

function Invoke-SSHPS {
    param([Parameter(Mandatory)][string]$NodeName, [Parameter(Mandatory)][string]$PsCommand)
    # Upload payload via scp to the remote home dir, then run with `powershell -File`.
    # Why: -EncodedCommand routes through cmd.exe on the Windows OpenSSH server, which
    # has an 8191-char command-line limit. Our payload exceeds that and was being silently
    # truncated, producing exit 0 with empty stdout. scp + -File sidesteps it entirely.
    $remoteName = "stress_payload_$([guid]::NewGuid().ToString('N')).ps1"
    $localTemp  = Join-Path $env:TEMP $remoteName
    Set-Content -Path $localTemp -Value $PsCommand -Encoding UTF8

    $scpTarget = if ($NodeName -match '@') { $NodeName } else { "$ssh_user@$NodeName" }
    Write-Host ("[$NodeName] payload={0}B  remote={1}  user={2}" -f $PsCommand.Length, $remoteName, $ssh_user)

    try {
        $scpArgs = "-O -o ConnectTimeout=15 -o UserKnownHostsFile=NUL -o StrictHostKeyChecking=no `"$localTemp`" `"${scpTarget}:$remoteName`""
        $psi = [System.Diagnostics.ProcessStartInfo]::new('scp')
        $psi.Arguments              = $scpArgs
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true
        $sp = [System.Diagnostics.Process]::Start($psi)
        $scpOut = $sp.StandardOutput.ReadToEnd()
        $scpErr = $sp.StandardError.ReadToEnd()
        $null = $sp.WaitForExit(60000)
        $scpExit = $sp.ExitCode
        $sp.Dispose()
        if ($scpExit -ne 0) {
            return [pscustomobject]@{ Output = ''; Error = "scp failed (exit $scpExit): $scpOut $scpErr"; ExitCode = 254 }
        }

        # Run via -File using cmd.exe %USERPROFILE% expansion; self-delete after.
        $remoteCmd = "powershell -NoLogo -NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"`$env:USERPROFILE\$remoteName`"; Remove-Item `"`$env:USERPROFILE\$remoteName`" -Force -ErrorAction SilentlyContinue"
        Invoke-SSH -NodeName $NodeName -TimeoutSec $ssh_timeout_secs -Command $remoteCmd
    } finally {
        Remove-Item $localTemp -Force -ErrorAction SilentlyContinue
    }
}

# ------------------ Start transcript ------------------
Ensure-Dir -Path $output_dir
$logFile = Join-Path $output_dir ("stress_sp3_list-{0}nodes_{1}.log" -f $targets.Count, $script:stamp)
Start-Transcript -Path $logFile -Append
Write-Host "Log : $logFile"
Write-Host ""

# ------------------ Remote payload ------------------
# $duration_secs is baked in at construction time (no backtick).
# All remote variables use backtick-escaped $.
$stressPayload = @"
`$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Busy check ---
`$wsp = `$null
foreach (`$p in @("C:\WINDOWS\SystemTemp", `$env:TMP, `$env:TEMP, `$env:USERPROFILE)) {
    if (`$p) { `$c = Join-Path `$p "worker-status.json"; if (Test-Path `$c) { `$wsp = `$c; break } }
}
`$busy = `$false
if (`$wsp) {
    try { `$j = Get-Content `$wsp -Raw | ConvertFrom-Json; if (@(`$j.currentTaskIds).Count -gt 0) { `$busy = `$true } } catch {}
}
if (`$busy) {
    [pscustomobject]@{ Status = 'busy'; Hostname = `$env:COMPUTERNAME } | ConvertTo-Json -Compress
    return
}

# --- Pre-clean leftover state from any abandoned prior StressSP3 run ---
# Only reached when busy=false, so we won't disturb a real CI task. Self-heals
# the node so a previous run's hung Firefox / scheduled task / xperf session
# doesn't break this one.
try { Get-Process firefox -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
try { `$null = & xperf -stop 2>`$null } catch {}
try {
    `$leftoverLogman = & logman query -ets 2>`$null | Select-String 'StressProcPower_'
    foreach (`$row in `$leftoverLogman) {
        `$lname = (`$row.Line -split '\s+')[0]
        if (`$lname) { try { `$null = & logman stop `$lname -ets 2>`$null } catch {} }
    }
} catch {}
try { Get-ScheduledTask -TaskName 'StressSP3_FF_*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:`$false -ErrorAction SilentlyContinue } catch {}
try { Remove-Item 'C:\Users\Public\sp3stress' -Recurse -Force -ErrorAction SilentlyContinue } catch {}

# --- Paths / timestamps ---
`$ts      = (Get-Date).ToString('yyyyMMddHHmmss')
`$dur     = $duration_secs
`$workDir = 'C:\Users\Public\sp3stress'
`$logDir  = 'C:\logs'
if (-not (Test-Path `$workDir)) { New-Item -ItemType Directory `$workDir -Force | Out-Null }
if (-not (Test-Path `$logDir))  { New-Item -ItemType Directory `$logDir  -Force | Out-Null }
`$kernelEtl   = Join-Path `$logDir "stress_kernel_`$ts.etl"
`$userEtl     = Join-Path `$logDir "stress_procpower_`$ts.etl"
`$sessionName = "StressProcPower_`$ts"
`$pyFile      = Join-Path `$workDir "marionette_`$ts.py"
`$pyOutFile   = Join-Path `$workDir "marionette_out_`$ts.txt"
`$pyErrFile   = Join-Path `$workDir "marionette_err_`$ts.txt"
`$ffProfile   = Join-Path `$workDir "ff_profile_`$ts"
`$ffSchedTask = "StressSP3_FF_`$ts"

# --- Locate xperf ---
`$xperfExe = @(
    'C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\xperf.exe',
    'C:\Program Files\Windows Kits\10\Windows Performance Toolkit\xperf.exe'
) | Where-Object { Test-Path `$_ } | Select-Object -First 1
`$xperfOK = `$null -ne `$xperfExe

# --- Firefox: check if already installed; only install (and uninstall) if not ---
`$ffPaths = @(
    'C:\Program Files\Mozilla Firefox\firefox.exe',
    'C:\Program Files (x86)\Mozilla Firefox\firefox.exe'
)
`$ffExe           = `$ffPaths | Where-Object { Test-Path `$_ } | Select-Object -First 1
`$ffAlreadyHere   = `$null -ne `$ffExe
`$chocoInstall    = `$false
`$chocoOutput     = ''
if (-not `$ffExe) {
    try   { `$chocoOutput = (& choco install firefox --yes --no-progress --limit-output --force 2>&1) -join "`n" }
    catch { `$chocoOutput = `$_.Exception.Message }
    `$chocoInstall = (`$LASTEXITCODE -eq 0)
    `$ffExe        = `$ffPaths | Where-Object { Test-Path `$_ } | Select-Object -First 1
}
`$ffOK = `$null -ne `$ffExe

# --- Python path ---
`$pythonCandidates = @(
    'C:\mozilla-build\python3\python3.exe',
    'C:\mozilla-build\python\python.exe',
    'C:\Python313\python.exe',
    'C:\Python312\python.exe',
    'C:\Python311\python.exe',
    'C:\Python310\python.exe'
)
`$pythonExe = `$pythonCandidates | Where-Object { Test-Path `$_ } | Select-Object -First 1
if (-not `$pythonExe) {
    foreach (`$cmd in 'python3','python','py') {
        try {
            `$found = & where.exe `$cmd 2>`$null
            if (`$found) { `$pythonExe = (`$found | Select-Object -First 1).Trim(); break }
        } catch {}
    }
}
`$pythonFound = (`$null -ne `$pythonExe -and (Test-Path `$pythonExe))

# --- Write Marionette Python script ---
# Navigates to SP3, starts it, then polls benchmarkClient._isRunning until the
# full benchmark completes. Exits only when SP3 is done (or max_polls exceeded).
`$pyContent = @'
import socket, json, time, sys

def recv_msg(s):
    buf = b''
    while b':' not in buf:
        c = s.recv(256)
        if not c:
            raise IOError('connection closed before delimiter')
        buf += c
    colon = buf.index(b':')
    n = int(buf[:colon])
    data = buf[colon+1:]
    while len(data) < n:
        data += s.recv(4096)
    return json.loads(data[:n].decode('utf-8'))

_mid = [0]
def send_cmd(s, cmd, params):
    _mid[0] += 1
    msg = json.dumps([0, _mid[0], cmd, params])
    s.sendall((str(len(msg)) + ':' + msg).encode('utf-8'))
    return recv_msg(s)

def script_value(r):
    # Marionette wraps WebDriver:ExecuteScript results in {"value": ...}
    v = r[3]
    if isinstance(v, dict) and 'value' in v:
        return v['value']
    return v

sock = None
for attempt in range(40):
    try:
        sock = socket.create_connection(('127.0.0.1', 2828), timeout=5)
        break
    except Exception as ex:
        if attempt == 39:
            print('MARIONETTE_CONNECT_FAILED:' + str(ex))
            sys.exit(1)
        time.sleep(1)

try:
    sock.settimeout(3)
    try:
        greeting = recv_msg(sock)
        print('GREETING:' + json.dumps(greeting))
    except socket.timeout:
        print('NO_GREETING')
    sock.settimeout(60)

    r = send_cmd(sock, 'WebDriver:NewSession', {'capabilities': {}})
    if r[2]:
        print('SESSION_ERROR:' + json.dumps(r[2]))
        sys.exit(1)
    sid = r[3].get('sessionId', 'none') if r[3] else 'none'
    print('SESSION:' + sid)

    # Run SP3 in a loop to match the wall-clock duration of CI Raptor/Browsertime
    # cycles (which restart Firefox per cycle ~25 times). We keep one Firefox
    # instance and re-navigate to the SP3 URL per loop, which approximates the
    # sustained CPU load CI puts on the worker over ~10 minutes total.
    SP3_LOOPS      = __SP3_LOOPS__
    SP3_ITERATIONS = __SP3_ITERATIONS__
    all_scores     = []
    fail_reason    = None
    max_polls      = 150  # 150 * 5s = 12.5 min per individual SP3 loop

    for loop_n in range(SP3_LOOPS):
        print('SP3_LOOP_BEGIN:' + str(loop_n + 1) + '/' + str(SP3_LOOPS))

        r = send_cmd(sock, 'WebDriver:Navigate', {'url': 'https://browserbench.org/Speedometer3.1/'})
        print('NAVIGATE_' + str(loop_n) + ':' + str(r[2]))

        page_ready = False
        for wait_n in range(30):
            r = send_cmd(sock, 'WebDriver:ExecuteScript', {
                'script': 'return document.readyState === "complete" ? "ready" : "not_ready";',
                'args': []
            })
            if str(script_value(r)) == 'ready':
                print('PAGE_READY_' + str(loop_n) + ':' + str(wait_n) + 's')
                page_ready = True
                break
            time.sleep(1)
        if not page_ready:
            print('PAGE_READY_TIMEOUT_' + str(loop_n))
            try:
                r = send_cmd(sock, 'WebDriver:ExecuteScript', {
                    'script': (
                        'try { return JSON.stringify({'
                        '  url: document.location ? document.location.href : null,'
                        '  title: document.title,'
                        '  state: document.readyState,'
                        '  body: document.body ? (document.body.innerText || "").substring(0, 400) : null'
                        '}); } catch(e) { return "ERR:" + e.message; }'
                    ),
                    'args': []
                })
                print('PAGE_DIAG_' + str(loop_n) + ':' + str(script_value(r)))
            except Exception as ex:
                print('PAGE_DIAG_ERROR_' + str(loop_n) + ':' + str(ex))
            fail_reason = 'page_load_timeout'
            break

        r = send_cmd(sock, 'WebDriver:ExecuteScript', {
            'script': (
                'try {'
                '  var n = ' + str(SP3_ITERATIONS) + ';'
                '  if (typeof benchmarkClient !== "undefined") {'
                '    try { benchmarkClient._iterationCount = n; } catch(_) {}'
                '    try { benchmarkClient.iterationCount  = n; } catch(_) {}'
                '    if (benchmarkClient._runner) {'
                '      try { benchmarkClient._runner._iterationCount = n; } catch(_) {}'
                '      try { benchmarkClient._runner.iterationCount  = n; } catch(_) {}'
                '    }'
                '  }'
                '  benchmarkClient.start(n);'
                '  var actual = (benchmarkClient && (benchmarkClient._iterationCount || benchmarkClient.iterationCount)) ||'
                '               (benchmarkClient && benchmarkClient._runner && (benchmarkClient._runner._iterationCount || benchmarkClient._runner.iterationCount)) ||'
                '               "unknown";'
                '  return "STARTED_API:requested=" + n + ",configured=" + actual;'
                '} catch(e1) {'
                '  var b = document.querySelector(".start-tests-button") ||'
                '          document.querySelector("#intro button") ||'
                '          document.querySelector("#home a.start") ||'
                '          document.querySelector("button");'
                '  if (!b) {'
                '    var cand = Array.from(document.querySelectorAll("a, button, [role=button], input[type=button], input[type=submit]"));'
                '    b = cand.find(function(e){ return /start.*test/i.test((e.textContent||"").trim()); }) ||'
                '        cand.find(function(e){ return /^\\s*start\\s*$/i.test((e.textContent||"").trim()); });'
                '  }'
                '  if (b) { b.click(); return "CLICKED_DOM:" + ((b.textContent||"").trim() || b.outerHTML.substring(0,100)); }'
                '  return "NO_METHOD:" + e1.message; }'
            ),
            'args': []
        })
        cv = script_value(r)
        click_result = str(cv) if cv is not None else 'null'
        print('SP3_CLICK_' + str(loop_n) + ':' + click_result)
        if click_result.startswith('NO_METHOD') or click_result == 'null':
            fail_reason = 'click_no_method'
            break
        time.sleep(2)

        # Poll until a final-score element with non-empty text appears. We do not
        # trust benchmarkClient._isRunning (it toggles per-subtest in SP3 3.1).
        poll_done = False
        for poll_n in range(max_polls):
            r = send_cmd(sock, 'WebDriver:ExecuteScript', {
                'script': (
                    'try {'
                    '  var s = document.querySelector('
                    '    "#result-number, .score-value, .score, .result-number, '
                    '    .summary .score, .summary-score"'
                    '  );'
                    '  if (s && s.textContent && s.textContent.trim()) {'
                    '    return "DONE:" + s.textContent.trim();'
                    '  }'
                    '  return "RUNNING";'
                    '} catch(e) { return "ERR:" + e.message; }'
                ),
                'args': []
            })
            sv = script_value(r)
            status = str(sv) if sv is not None else 'null'
            # Reduce poll noise: only log every 6 polls (~30s), at start, and on DONE.
            if poll_n == 0 or (poll_n % 6 == 0) or status.startswith('DONE:'):
                print('SP3_POLL_' + str(loop_n) + '_' + str(poll_n) + ':' + status)
            if status.startswith('DONE:'):
                if loop_n == 0:
                    try:
                        d = send_cmd(sock, 'WebDriver:ExecuteScript', {
                            'script': (
                                'try { return JSON.stringify({'
                                '  url: document.location ? document.location.href : null,'
                                '  title: document.title,'
                                '  body: document.body ? (document.body.innerText || "").substring(0, 400) : null'
                                '}); } catch(e) { return "ERR:" + e.message; }'
                            ),
                            'args': []
                        })
                        print('SP3_DONE_DIAG:' + str(script_value(d)))
                    except Exception as ex:
                        print('SP3_DONE_DIAG_ERROR:' + str(ex))
                score = status[5:]
                all_scores.append(score)
                print('SP3_DONE_' + str(loop_n) + ':' + score)
                print('SP3_RUN_SECONDS_' + str(loop_n) + ':' + str(poll_n * 5))
                poll_done = True
                break
            time.sleep(5)
        if not poll_done:
            print('SP3_POLL_TIMEOUT_' + str(loop_n))
            fail_reason = 'poll_timeout'
            break

    # Summary across all loops
    print('SP3_SCORES_ALL:' + ','.join(all_scores))
    print('SP3_LOOPS_COMPLETED:' + str(len(all_scores)) + '/' + str(SP3_LOOPS))
    if all_scores:
        # Emit a final SP3_DONE/REASON pair so the existing PowerShell parser still works.
        print('SP3_DONE:' + all_scores[-1])
        print('SP3_REASON:completed' if len(all_scores) == SP3_LOOPS else ('SP3_REASON:' + (fail_reason or 'partial')))
    elif fail_reason:
        print('SP3_REASON:' + fail_reason)
    else:
        print('SP3_REASON:no_score')

except Exception as ex:
    print('MARIONETTE_ERROR:' + str(ex))
    sys.exit(1)
finally:
    if sock:
        try: sock.close()
        except: pass
print('MARIONETTE_DONE')
'@
# Inject SP3 iteration count + loop count (baked in at construction time on the local side)
`$pyContent = `$pyContent.Replace('__SP3_ITERATIONS__', '$sp3_iterations')
`$pyContent = `$pyContent.Replace('__SP3_LOOPS__',      '$sp3_loops')
`$pyContent | Set-Content `$pyFile -Encoding UTF8

# --- Pre-clean any leftover ETW sessions from prior crashed runs ---
# NT Kernel Logger is a singleton session: if a previous xperf -stop didn't run
# (script killed, host rebooted, etc.) the next xperf -on fails with 0xb7.
# All native invocations are wrapped in try/catch because under \$ErrorActionPreference=Stop,
# any stderr output from a native command produces an ErrorRecord that terminates the script
# even with 2>\$null redirection.
if (`$xperfOK) {
    try { `$null = & `$xperfExe -stop 2>`$null } catch {}
}
try { `$null = & logman stop `$sessionName -ets 2>`$null } catch {}

# --- Start xperf kernel POWER trace ---
`$xperfStarted = `$false
if (`$xperfOK) {
    try {
        `$null = & `$xperfExe -on 'PROC_THREAD+LOADER+POWER' -BufferSize 512 -MinBuffers 32 -MaxBuffers 96 -f `$kernelEtl 2>`$null
        `$xperfStarted = (`$LASTEXITCODE -eq 0)
    } catch {}
}

# --- Start logman user-mode ETW: Microsoft-Windows-Kernel-Processor-Power ---
`$logmanStarted = `$false
try {
    `$null = & logman create trace `$sessionName ``
        -p 'Microsoft-Windows-Kernel-Processor-Power' 0xFFFFFFFFFFFFFFFF 0xff ``
        -o `$userEtl -max 256 -ets 2>`$null
    `$logmanStarted = (`$LASTEXITCODE -eq 0)
} catch {}

# --- Create fresh Firefox profile dir ---
if (-not (Test-Path `$ffProfile)) { New-Item -ItemType Directory `$ffProfile -Force | Out-Null }

# --- Detect active interactive task user (non-Administrator) via `query user` ---
`$taskUser    = `$null
`$taskSession = `$null
try {
    `$qu = & query user 2>`$null
    foreach (`$line in `$qu) {
        # Active rows look like:  ">user-name              console     1   Active   .  date"
        # The leading ">" marks the current session (Administrator running this script).
        if (`$line -match '^\s*>?\s*(\S+)\s+\S+\s+(\d+)\s+Active') {
            `$u = `$matches[1]
            `$s = [int]`$matches[2]
            if (`$u -notmatch '^(Administrator|administrator|SYSTEM)$' -and `$u -ne `$env:USERNAME) {
                `$taskUser    = `$u
                `$taskSession = `$s
                break
            }
        }
    }
} catch {}

# --- Start Firefox headless with Marionette ---
# Launches in the task user's interactive session via a one-shot scheduled task
# (LogonType=Interactive uses the user's existing logon token — no password needed).
# Falls back to Start-Process in the Administrator session if no task user is logged in.
`$ffStarted    = `$false
`$ffProc       = `$null
`$ffLaunchMode = 'none'
if (`$ffOK) {
    `$ffArgs = '$(if ($visible) { "" } else { "--headless " })--marionette --no-remote --new-instance -profile ' + `$ffProfile
    if (`$taskUser) {
        try {
            `$ffLaunchMode = 'scheduled_task'
            `$action    = New-ScheduledTaskAction -Execute `$ffExe -Argument `$ffArgs
            `$principal = New-ScheduledTaskPrincipal -UserId "`$env:COMPUTERNAME\`$taskUser" -LogonType Interactive
            `$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
            `$taskDef   = New-ScheduledTask -Action `$action -Principal `$principal -Settings `$settings
            Register-ScheduledTask -TaskName `$ffSchedTask -InputObject `$taskDef -Force | Out-Null
            Start-ScheduledTask -TaskName `$ffSchedTask
            # Poll up to 15s for an actual firefox.exe to appear in a non-zero session.
            for (`$w = 0; `$w -lt 15; `$w++) {
                Start-Sleep -Seconds 1
                `$candidates = Get-Process firefox -ErrorAction SilentlyContinue
                if (`$candidates) { `$ffStarted = `$true; break }
            }
        } catch {
            `$ffLaunchMode = "scheduled_task_failed:`$(`$_.Exception.Message -replace "`r`n",' ')"
        }
    } else {
        `$ffLaunchMode = 'admin_fallback'
        `$ffProc = Start-Process -FilePath `$ffExe -ArgumentList `$ffArgs -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 8
        `$ffStarted = (`$null -ne `$ffProc -and -not `$ffProc.HasExited)
    }
}

# --- Start Marionette Python script as a background process ---
# It navigates to SP3, clicks Start, and polls until the benchmark finishes.
# Note: Start-Process refuses if stdout and stderr point to the same path, so we
# use two files and merge them after the process exits.
`$pyProc    = `$null
`$pyStarted = `$false
if (`$ffStarted -and `$pythonFound -and (Test-Path `$pyFile)) {
    try {
        `$pyProc = Start-Process -FilePath `$pythonExe -ArgumentList `$pyFile ``
            -RedirectStandardOutput `$pyOutFile -RedirectStandardError `$pyErrFile ``
            -WindowStyle Hidden -PassThru -ErrorAction Stop
        `$pyStarted = (`$null -ne `$pyProc)
    } catch {
        `$pyStartError = `$_.Exception.Message -replace "`r`n",' '
    }
}

# --- CPU sampling loop ---
# Runs until the Marionette script exits (SP3 done) or `$dur seconds elapse (safety cap).
`$t0         = Get-Date
`$cpuSamples = [System.Collections.Generic.List[double]]::new()
`$deadline   = `$t0.AddSeconds(`$dur)
`$ffCrashed = `$false
while ((Get-Date) -lt `$deadline) {
    if (`$null -ne `$pyProc -and `$pyProc.HasExited) { break }
    # Firefox-crash check: works for both Start-Process (admin fallback) and scheduled-task launch
    if (`$ffStarted) {
        `$ffAlive = @(Get-Process firefox -ErrorAction SilentlyContinue).Count -gt 0
        if (-not `$ffAlive) { `$ffCrashed = `$true; break }
    }
    try {
        `$ctr = (Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction Stop).CounterSamples[0].CookedValue
        `$cpuSamples.Add([math]::Round(`$ctr, 1))
    } catch {}
    Start-Sleep -Seconds 4
}
`$t1 = Get-Date

# --- Read Marionette output (merge stdout and stderr) ---
`$marionetteOut = ''
`$pyExitCode   = `$null
# Give Python up to 5s to flush its output file if it just exited
if (`$null -ne `$pyProc -and -not `$pyProc.HasExited) {
    `$null = `$pyProc.WaitForExit(5000)
}
if (`$null -ne `$pyProc) { `$pyExitCode = `$pyProc.ExitCode }
# Get-Content -Raw returns \$null on an empty file in PS 5.1 (not empty string),
# so we must null-check before calling .Trim().
if (Test-Path `$pyOutFile) {
    `$rawOut = Get-Content `$pyOutFile -Raw -ErrorAction SilentlyContinue
    if (`$rawOut) { `$marionetteOut = `$rawOut.Trim() }
}
if (Test-Path `$pyErrFile) {
    `$rawErr = Get-Content `$pyErrFile -Raw -ErrorAction SilentlyContinue
    if (`$rawErr) {
        `$errContent = `$rawErr.Trim()
        if (`$marionetteOut) { `$marionetteOut += "`n--- STDERR ---`n" + `$errContent }
        else                 { `$marionetteOut  = "--- STDERR ---`n" + `$errContent }
    }
}

`$sp3Started  = `$marionetteOut -match 'STARTED_API|CLICKED_DOM'
`$sp3Finished = `$marionetteOut -match 'SP3_DONE:'
`$sp3ScoreM   = [regex]::Match(`$marionetteOut, 'SP3_DONE:(\S+)')
`$sp3Score    = if (`$sp3ScoreM.Success) { `$sp3ScoreM.Groups[1].Value.Trim() } else { '' }
`$sp3AllM     = [regex]::Match(`$marionetteOut, 'SP3_SCORES_ALL:(\S*)')
`$sp3AllScores = if (`$sp3AllM.Success) { `$sp3AllM.Groups[1].Value.Trim() } else { '' }
`$sp3LoopsM   = [regex]::Match(`$marionetteOut, 'SP3_LOOPS_COMPLETED:(\S+)')
`$sp3Loops    = if (`$sp3LoopsM.Success) { `$sp3LoopsM.Groups[1].Value.Trim() } else { '' }
`$sp3ReasonM  = [regex]::Match(`$marionetteOut, 'SP3_REASON:(\S+)')
`$sp3Reason   = if (`$sp3ReasonM.Success) { `$sp3ReasonM.Groups[1].Value.Trim() }
               elseif (`$ffCrashed)        { 'firefox_crashed' }
               elseif (`$marionetteOut -match 'MARIONETTE_CONNECT_FAILED') { 'marionette_connect_failed' }
               elseif (-not `$marionetteOut) { 'no_marionette_output' }
               else                          { 'unknown' }

# --- Kill Marionette Python if still running (safety cap hit) ---
if (`$null -ne `$pyProc -and -not `$pyProc.HasExited) {
    Stop-Process -Id `$pyProc.Id -Force -ErrorAction SilentlyContinue
}

# --- Kill Firefox and clean up its profile + scheduled task ---
if (`$null -ne `$ffProc) {
    Stop-Process -Id `$ffProc.Id -Force -ErrorAction SilentlyContinue
}
Get-Process -Name firefox -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
try { Unregister-ScheduledTask -TaskName `$ffSchedTask -Confirm:`$false -ErrorAction SilentlyContinue } catch {}
Remove-Item `$ffProfile -Recurse -Force -ErrorAction SilentlyContinue

# --- Stop xperf (correct cleanup is `-stop`; `-d` requires a file arg and is for a different mode) ---
`$xperfStopOK = `$false
if (`$xperfOK -and `$xperfStarted) {
    try {
        `$null = & `$xperfExe -stop 2>`$null
        `$xperfStopOK = (`$LASTEXITCODE -eq 0)
    } catch {}
}

# --- Stop logman ---
if (`$logmanStarted) {
    try { `$null = & logman stop `$sessionName -ets 2>`$null } catch {}
}

# --- System event log: Ev37/55 ---
`$evs = try {
    Get-WinEvent -FilterHashtable @{
        LogName      = 'System'
        ProviderName = 'Microsoft-Windows-Kernel-Processor-Power'
        StartTime    = `$t0; EndTime = `$t1
    } -ErrorAction Stop | Where-Object { `$_.Id -in 37, 55 }
} catch { @() }
`$e37 = @(`$evs | Where-Object { `$_.Id -eq 37 })
`$e55 = @(`$evs | Where-Object { `$_.Id -eq 55 })

`$byp = `$e37 |
    Group-Object { ([regex]::Match(`$_.Message, '(?i)processor\s+(\d+)')).Groups[1].Value } |
    Sort-Object { [int]`$_.Name } |
    ForEach-Object { [pscustomobject]@{ Proc = `$_.Name; Count = `$_.Count } }
`$bpj = if (`$byp) { `$byp | ConvertTo-Json -Compress } else { '[]' }

`$p55 = foreach (`$x in `$e55) {
    `$m  = `$x.Message
    `$pc = ([regex]::Match(`$m, '(?i)processor\s+(\d+)')).Groups[1].Value
    `$mp = ([regex]::Match(`$m, 'Minimum performance percentage:\s+(\d+)')).Groups[1].Value
    if (`$pc -and `$mp) { [pscustomobject]@{ Proc = [int]`$pc; MinPct = [int]`$mp } }
}
`$wst = if (`$p55) { (`$p55 | Measure-Object MinPct -Minimum).Minimum } else { `$null }
`$avg = if (`$p55) { [math]::Round((`$p55 | Measure-Object MinPct -Average).Average, 1) } else { `$null }

# --- Parse logman ETL: counts of throttling-related event IDs only ---
# Use FilterXPath so Get-WinEvent only materializes the events we care about.
# Reading every event in the ETL (1.5M+ for a 12-loop run) takes 10+ minutes
# and previously caused SSH timeouts before the result JSON could be emitted.
`$xEv37 = 0; `$xEv48 = 0; `$xEv51 = 0; `$xEv55 = 0; `$xEv58 = 0
`$xEv48MinPct = `$null; `$xEv51MinPct = `$null
`$xEvOther = ''; `$xEvError = ''
if (`$logmanStarted -and (Test-Path `$userEtl)) {
    try {
        `$xpath = "*[System[(EventID=37 or EventID=48 or EventID=51 or EventID=55 or EventID=58)]]"
        `$relevantEvts = @(Get-WinEvent -Path `$userEtl -Oldest -FilterXPath `$xpath -ErrorAction Stop |
            Where-Object { `$_.TimeCreated -ge `$t0 -and `$_.TimeCreated -le `$t1 })
        `$xEv37 = @(`$relevantEvts | Where-Object { `$_.Id -eq 37 }).Count
        `$xEv48 = @(`$relevantEvts | Where-Object { `$_.Id -eq 48 }).Count
        `$xEv51 = @(`$relevantEvts | Where-Object { `$_.Id -eq 51 }).Count
        `$xEv55 = @(`$relevantEvts | Where-Object { `$_.Id -eq 55 }).Count
        `$xEv58 = @(`$relevantEvts | Where-Object { `$_.Id -eq 58 }).Count
        foreach (`$ev in (`$relevantEvts | Where-Object { `$_.Id -eq 48 })) {
            `$mp = ([regex]::Match(`$ev.Message, 'Minimum performance percentage:\s+(\d+)')).Groups[1].Value
            if (`$mp) { `$v = [int]`$mp; if (`$null -eq `$xEv48MinPct -or `$v -lt `$xEv48MinPct) { `$xEv48MinPct = `$v } }
        }
        foreach (`$ev in (`$relevantEvts | Where-Object { `$_.Id -eq 51 })) {
            `$mp = ([regex]::Match(`$ev.Message, 'Minimum performance percentage:\s+(\d+)')).Groups[1].Value
            if (`$mp) { `$v = [int]`$mp; if (`$null -eq `$xEv51MinPct -or `$v -lt `$xEv51MinPct) { `$xEv51MinPct = `$v } }
        }
    } catch { `$xEvError = `$_.ToString() -replace "`r`n",' ' }
}

# --- xperf cpufreq analysis ---
`$xFreqSummary = ''; `$xFreqError = ''
if (`$xperfOK -and `$xperfStopOK -and (Test-Path `$kernelEtl)) {
    try {
        `$rawFreq = & `$xperfExe -i `$kernelEtl -a cpufreq 2>&1
        `$freqMap = @{}
        foreach (`$line in `$rawFreq) {
            `$m = [regex]::Match(`$line, '(\d{3,5})\s+(\d+\.\d+)')
            if (`$m.Success) {
                `$mhz = [int]`$m.Groups[1].Value
                `$pct = [double]`$m.Groups[2].Value
                if (`$freqMap.ContainsKey(`$mhz)) { `$freqMap[`$mhz] += `$pct } else { `$freqMap[`$mhz] = `$pct }
            }
        }
        if (`$freqMap.Count -gt 0) {
            `$xFreqSummary = (`$freqMap.GetEnumerator() | Sort-Object Key -Descending |
                ForEach-Object { "`$(`$_.Key)MHz:`$([math]::Round(`$_.Value/`$freqMap.Count,1))%" }) -join ' | '
        } else {
            `$xFreqSummary = ((`$rawFreq -join ' | ') -replace '\s+',' ').Substring(0, [math]::Min(2000,((`$rawFreq -join ' | ').Length)))
        }
    } catch { `$xFreqError = `$_.ToString() -replace "`r`n",' ' }
}

# --- Cleanup ---
Remove-Item `$kernelEtl  -Force -ErrorAction SilentlyContinue
Remove-Item `$userEtl    -Force -ErrorAction SilentlyContinue
Remove-Item `$pyFile     -Force -ErrorAction SilentlyContinue
Remove-Item `$pyOutFile  -Force -ErrorAction SilentlyContinue
Remove-Item `$pyErrFile  -Force -ErrorAction SilentlyContinue

# --- Choco uninstall Firefox (only if we installed it) ---
`$chocoUninstall = `$false
if (`$chocoInstall) {
    try   { `$null = & choco uninstall firefox --yes --no-progress --limit-output 2>&1 } catch {}
    `$chocoUninstall = (`$LASTEXITCODE -eq 0)
}

# --- RAM inventory ---
`$totalMem   = [long](Get-WmiObject Win32_ComputerSystem).TotalPhysicalMemory
`$ramDimms   = @(Get-WmiObject Win32_PhysicalMemory)
`$ramSlots   = `$ramDimms.Count
`$ramTotalGB = [math]::Round(`$totalMem / 1GB, 1)
`$ramSpeeds  = (`$ramDimms | ForEach-Object { `$_.Speed } | Sort-Object -Unique) -join '/'
`$ramSizes   = (`$ramDimms | ForEach-Object { [math]::Round(`$_.Capacity / 1GB, 0) }) -join '+'
`$ramChannel = if (`$ramSlots -ge 2) { 'dual' } else { 'single' }

# --- Build result ---
`$sec = [math]::Round((`$t1 - `$t0).TotalSeconds, 2)
`$cn  = (Get-WmiObject Win32_Processor | Select-Object -First 1).Name
`$nc  = [Environment]::ProcessorCount

[pscustomobject]@{
    Status          = 'ok'
    Hostname        = `$env:COMPUTERNAME
    Timestamp       = `$t0.ToString('s')
    CPU             = `$cn
    Cores           = `$nc
    RAM_GB          = `$ramTotalGB
    RAM_Slots       = `$ramSlots
    RAM_Channel     = `$ramChannel
    RAM_SpeedMHz    = `$ramSpeeds
    RAM_Config      = `$ramSizes
    DurSec          = `$dur
    ActSec          = `$sec
    CPU_MinPct      = if (`$cpuSamples.Count -gt 0) { [math]::Round((`$cpuSamples | Measure-Object -Minimum).Minimum, 1) } else { `$null }
    CPU_MaxPct      = if (`$cpuSamples.Count -gt 0) { [math]::Round((`$cpuSamples | Measure-Object -Maximum).Maximum, 1) } else { `$null }
    CPU_AvgPct      = if (`$cpuSamples.Count -gt 0) { [math]::Round((`$cpuSamples | Measure-Object -Average).Average, 1) } else { `$null }
    CPU_Samples     = `$cpuSamples -join ','
    Choco_Install   = `$chocoInstall
    Choco_Output    = (`$chocoOutput -replace "`r`n",' ')
    FF_AlreadyHere  = `$ffAlreadyHere
    FF_OK           = `$ffOK
    FF_Started      = `$ffStarted
    FF_LaunchMode   = `$ffLaunchMode
    TaskUser        = `$taskUser
    TaskSession     = `$taskSession
    Python_Found    = `$pythonFound
    Python_Exe      = `$pythonExe
    Python_Started  = `$pyStarted
    Python_ExitCode = `$pyExitCode
    SP3_Started     = `$sp3Started
    SP3_Finished    = `$sp3Finished
    SP3_Score       = `$sp3Score
    SP3_AllScores   = `$sp3AllScores
    SP3_Loops       = `$sp3Loops
    SP3_Reason      = `$sp3Reason
    FF_Crashed      = `$ffCrashed
    Marionette_Out  = (`$marionetteOut -replace "`r`n",' ')
    Choco_Uninstall = `$chocoUninstall
    Ev37            = `$e37.Count
    Ev37_ByProc     = `$bpj
    Ev55            = `$e55.Count
    Ev55_Worst      = `$wst
    Ev55_Avg        = `$avg
    Xperf_OK        = `$xperfOK
    Xperf_Started   = `$xperfStarted
    Logman_OK       = `$logmanStarted
    XEv37           = `$xEv37
    XEv48           = `$xEv48
    XEv51           = `$xEv51
    XEv55           = `$xEv55
    XEv58           = `$xEv58
    XEv_Other       = `$xEvOther
    XEv48_MinPct    = `$xEv48MinPct
    XEv51_MinPct    = `$xEv51MinPct
    XFreq_Summary   = `$xFreqSummary
    XFreq_Error     = `$xFreqError
    XEv_Error       = `$xEvError
} | ConvertTo-Json -Depth 5 -Compress
"@

# ------------------ Test-remote override (small payload to bisect transport vs. real payload) ------------------
if ($test_remote) {
    $stressPayload = @"
[pscustomobject]@{
    Status     = 'ok_test'
    Hostname   = `$env:COMPUTERNAME
    PSVersion  = `$PSVersionTable.PSVersion.ToString()
    Now        = (Get-Date).ToString('s')
    PayloadLen = 999
} | ConvertTo-Json -Compress
"@
    Write-Host "TEST_REMOTE: using minimal payload to verify SSH+EncodedCommand transport"
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
            [int]$SshTimeoutSecs,
            [bool]$DryRun,
            [string]$SshUser,
            [System.Collections.Concurrent.ConcurrentQueue[string]]$MsgQueue
        )

        function Log { param([string]$Msg) $MsgQueue.Enqueue($Msg) }

        function Invoke-SSH {
            param([string]$NodeName, [string]$Command, [int]$TimeoutSec = 600, [string]$StdinText = "")
            $target = if ($NodeName -match '@') { $NodeName } else { "$SshUser@$NodeName" }
            $psi = [System.Diagnostics.ProcessStartInfo]::new('ssh')
            $psi.Arguments              = "-o ConnectTimeout=15 -o UserKnownHostsFile=NUL -o StrictHostKeyChecking=no $target $Command"
            $psi.UseShellExecute        = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.RedirectStandardInput  = $true
            $psi.CreateNoWindow         = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $outTask = $p.StandardOutput.ReadToEndAsync()
            $errTask = $p.StandardError.ReadToEndAsync()
            if ($StdinText) { $p.StandardInput.Write($StdinText) }
            $p.StandardInput.Close()
            $exited  = $p.WaitForExit($TimeoutSec * 1000)
            if (-not $exited) { try { $p.Kill() } catch {} }
            $null = $outTask.Wait(10000)
            $null = $errTask.Wait(10000)
            $stdout   = if ($outTask.Status -eq 'RanToCompletion') { $outTask.Result } else { '' }
            $stderr   = if ($errTask.Status -eq 'RanToCompletion') { $errTask.Result } else { '' }
            $exitCode = if ($exited) { $p.ExitCode } else { 255 }
            $p.Dispose()
            [pscustomobject]@{ Output = $stdout; Error = $stderr; ExitCode = $exitCode }
        }
        function Invoke-SSHPS {
            param([string]$NodeName, [string]$PsCommand)
            $remoteName = "stress_payload_$([guid]::NewGuid().ToString('N')).ps1"
            $localTemp  = Join-Path $env:TEMP $remoteName
            Set-Content -Path $localTemp -Value $PsCommand -Encoding UTF8

            $scpTarget = if ($NodeName -match '@') { $NodeName } else { "$SshUser@$NodeName" }
            Log ("[$NodeName] payload={0}B  remote={1}  user={2}" -f $PsCommand.Length, $remoteName, $SshUser)

            try {
                $scpArgs = "-O -o ConnectTimeout=15 -o UserKnownHostsFile=NUL -o StrictHostKeyChecking=no `"$localTemp`" `"${scpTarget}:$remoteName`""
                $psi = [System.Diagnostics.ProcessStartInfo]::new('scp')
                $psi.Arguments              = $scpArgs
                $psi.UseShellExecute        = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError  = $true
                $psi.CreateNoWindow         = $true
                $sp = [System.Diagnostics.Process]::Start($psi)
                $scpOut = $sp.StandardOutput.ReadToEnd()
                $scpErr = $sp.StandardError.ReadToEnd()
                $null = $sp.WaitForExit(60000)
                $scpExit = $sp.ExitCode
                $sp.Dispose()
                if ($scpExit -ne 0) {
                    return [pscustomobject]@{ Output = ''; Error = "scp failed (exit $scpExit): $scpOut $scpErr"; ExitCode = 254 }
                }

                $remoteCmd = "powershell -NoLogo -NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"`$env:USERPROFILE\$remoteName`"; Remove-Item `"`$env:USERPROFILE\$remoteName`" -Force -ErrorAction SilentlyContinue"
                Invoke-SSH -NodeName $NodeName -TimeoutSec $SshTimeoutSecs -Command $remoteCmd
            } finally {
                Remove-Item $localTemp -Force -ErrorAction SilentlyContinue
            }
        }

        if ($DryRun) { Log "[$Fqdn] DRY RUN"; return [pscustomobject]@{ _s = 'dry'; Fqdn = $Fqdn } }

        Log "[$Fqdn] Connecting..."
        $res = Invoke-SSHPS -NodeName $Fqdn -PsCommand $StressPayload
        $out = ($res.Output | Out-String).Trim()
        $err = if ($res.PSObject.Properties['Error']) { ($res.Error | Out-String).Trim() } else { '' }

        if ($err) {
            $errSnippet = if ($err.Length -gt 2000) { $err.Substring(0, 2000) + "...[truncated]" } else { $err }
            Log "[$Fqdn] RAW STDERR (len=$($err.Length)): $errSnippet"
        }

        if ($res.ExitCode -eq 255) { Log "[$Fqdn] SSH connection failed.";                return [pscustomobject]@{ _s = 'err'; Fqdn = $Fqdn } }
        if ($res.ExitCode -ne 0)   { Log "[$Fqdn] Remote failed (exit $($res.ExitCode))."; return [pscustomobject]@{ _s = 'err'; Fqdn = $Fqdn } }

        $rawSnippet = if ($out.Length -gt 1500) { $out.Substring(0, 1500) + "...[truncated]" } else { $out }
        Log "[$Fqdn] RAW STDOUT (len=$($out.Length)): $rawSnippet"

        if ([string]::IsNullOrWhiteSpace($out)) {
            Log "[$Fqdn] Remote returned empty stdout with exit 0 (stderr above, if any)."
            return [pscustomobject]@{ _s = 'err'; Fqdn = $Fqdn }
        }

        try   { $obj = $out | ConvertFrom-Json }
        catch { Log "[$Fqdn] No JSON in output.`n$out"; return [pscustomobject]@{ _s = 'err'; Fqdn = $Fqdn } }

        if ($obj.Status -eq 'busy') { Log "[$Fqdn] Busy (task running)."; return [pscustomobject]@{ _s = 'busy'; Fqdn = $Fqdn } }

        Log ("[$Fqdn] Done  Ev37={0}  CPU_Min={1}%  CPU_Avg={2}%  XEv37={3}  XEv48={4}  XEv51={5}  XEv58={6}  FF={7}  Mode={8}  TaskUser={9}  SP3_Done={10}  Reason={11}  Score={12}  Loops={13}  Scores=[{14}]  ActSec={15}" -f
            $obj.Ev37, $obj.CPU_MinPct, $obj.CPU_AvgPct,
            $obj.XEv37, $obj.XEv48, $obj.XEv51, $obj.XEv58,
            $obj.FF_Started, $obj.FF_LaunchMode, $obj.TaskUser,
            $obj.SP3_Finished, $obj.SP3_Reason, $obj.SP3_Score,
            $obj.SP3_Loops, $obj.SP3_AllScores, $obj.ActSec)
        if ($obj.XFreq_Summary)  { Log "[$Fqdn] CpuFreq: $($obj.XFreq_Summary)" }
        if ($obj.Marionette_Out) { Log "[$Fqdn] Marionette: $($obj.Marionette_Out)" }
        if ($obj.XEv_Error)      { Log "[$Fqdn] ETL parse error: $($obj.XEv_Error)" }
        if ($obj.XFreq_Error)    { Log "[$Fqdn] cpufreq error: $($obj.XFreq_Error)" }
        return $obj
    }

    function Drain-Queue {
        $msg = $null
        while ($msgQueue.TryDequeue([ref]$msg)) { Write-Host $msg; $msg = $null }
    }

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
                Fqdn           = $fqdn
                StressPayload  = $stressPayload
                DurationSecs   = $duration_secs
                SshTimeoutSecs = $ssh_timeout_secs
                DryRun         = [bool]$dry_run
                SshUser        = $ssh_user
                MsgQueue       = $msgQueue
            })
            $jobs.Add([pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); Fqdn = $fqdn })
        }

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
                catch { $msgQueue.Enqueue("[$($job.Fqdn)] Runspace error: $_"); $r = [pscustomobject]@{ _s = 'err'; Fqdn = $job.Fqdn } }
                $job.PS.Dispose()

                $rs = if ($r -and $r.PSObject.Properties['_s']) { $r._s } else { $null }
                if     ($null -eq $r -or $rs -eq 'dry')  { }
                elseif ($rs -eq 'err')                    { if ($script:failed_ssh  -notcontains $job.Fqdn) { $script:failed_ssh  += $job.Fqdn } }
                elseif ($rs -eq 'busy')                   { if ($script:busy_nodes  -notcontains $job.Fqdn) { $script:busy_nodes  += $job.Fqdn } }
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
Write-Host "     STRESS + SP3 FULL RUN + ETW POWER CAPTURE              "
Write-Host ("   Nodes: {0}   Batches of: {1}   Max wait: {2}s   Dry run: {3}" -f $targets.Count, $max_parallel, $duration_secs, $dry_run)
Write-Host "------------------------------------------------------------"
Write-Host ""
Write-Host "Target nodes:"
$target_shorts | ForEach-Object { Write-Host "  $_" }
Write-Host ""

Invoke-Parallel -Fqdns $targets

# ------------------ Busy retry loop ------------------
$busyPass = 0
while (-not $no_retry -and $script:busy_nodes.Count -gt 0) {
    $busyPass++
    $pending           = @($script:busy_nodes | Sort-Object -Unique)
    $script:busy_nodes = @()
    Sleep-BetweenPasses -Seconds $retry_sleep_secs -Label "busy retry $busyPass - $($pending.Count) node(s)"
    Write-Host "---- BUSY RETRY $busyPass ($($pending.Count) node(s)) ----"
    Invoke-Parallel -Fqdns $pending
}

# ------------------ SSH retry loop ------------------
$sshPass = 0
while (-not $no_retry -and $script:failed_ssh.Count -gt 0 -and $sshPass -lt $ssh_max_retries) {
    $sshPass++
    $retry             = @($script:failed_ssh | Sort-Object -Unique)
    $script:failed_ssh = @()
    Sleep-BetweenPasses -Seconds $retry_sleep_secs -Label "SSH retry $sshPass of $ssh_max_retries - $($retry.Count) node(s)"
    Write-Host "---- SSH RETRY $sshPass of $ssh_max_retries ($($retry.Count) node(s)) ----"
    Invoke-Parallel -Fqdns $retry -IsRetry

    while ($script:busy_nodes.Count -gt 0) {
        $busyPass++
        $pending           = @($script:busy_nodes | Sort-Object -Unique)
        $script:busy_nodes = @()
        Sleep-BetweenPasses -Seconds $retry_sleep_secs -Label "busy retry $busyPass (during SSH retry)"
        Invoke-Parallel -Fqdns $pending
    }
}

# ------------------ CSV output ------------------
$outCsv = Join-Path $output_dir ("stress_sp3_list-{0}nodes_{1}.csv" -f $targets.Count, $script:stamp)

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
Write-Host ("Max wait per node : {0}s" -f $duration_secs)
Write-Host ("Nodes targeted    : {0}"  -f $targets.Count)
Write-Host ""

$good = @($script:results | Where-Object { -not $_.PSObject.Properties['Error'] })
if ($good.Count -gt 0) {
    $good |
        Select-Object Hostname, ActSec, CPU_MinPct, CPU_AvgPct, SP3_Finished, SP3_Reason, SP3_Score,
                      SP3_Loops, SP3_AllScores,
                      Ev37, Ev55_Worst, XEv37, XEv48, XEv51, XEv58,
                      XEv48_MinPct, XEv51_MinPct, Xperf_OK, Logman_OK, FF_Started, FF_Crashed,
                      FF_LaunchMode, TaskUser, TaskSession |
        Sort-Object @{e='Ev37';d=1}, @{e='XEv48';d=1} |
        Format-Table -AutoSize |
        Out-String |
        Write-Host
}

if (@($script:failed_ssh).Count -gt 0) {
    Write-Host "Failed (after all retries):"
    $script:failed_ssh | Sort-Object -Unique | ForEach-Object { Write-Host "  - $_" }
} else {
    Write-Host "Failed: none"
}

if (@($script:retry_recovered).Count -gt 0) {
    Write-Host ""
    Write-Host "Recovered on retry:"
    $script:retry_recovered | Sort-Object -Unique | ForEach-Object { Write-Host "  - $_" }
}

Write-Host ""
Write-Host "Log : $logFile"
Write-Host "CSV : $outCsv"

Stop-Transcript
