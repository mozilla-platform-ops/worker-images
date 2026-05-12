# Compare-NUCHealth.ps1
# Side-by-side hardware/firmware/software comparison across NUC13 nodes.
# Designed for diffing the SP3 throttling-investigation compare set:
#   nuc13-009 (good) vs nuc13-010 (susp PSU) vs nuc13-029 (bad, unknown).
#
# Per node, captures a quick (<60s) snapshot of:
#   - active power plan + min/max processor state
#   - CPU model, max clock, current clock, achieved %perf under brief load
#   - RAM total / channel / per-DIMM (speed, capacity, manufacturer, part, location)
#   - storage media type + model + bus + size for each physical disk
#   - BIOS version + release date
#   - top 5 processes by CPU and by working set
#   - OS build + uptime
#
# Output: prints a side-by-side comparison table (one row per metric, one column per node).
#
# Usage:
#   .\Compare-NUCHealth.ps1                                    # default 3-node compare set
#   .\Compare-NUCHealth.ps1 -nodes "nuc13-029"                 # one node
#   .\Compare-NUCHealth.ps1 -nodes "nuc13-009,nuc13-010"       # custom list
#   .\Compare-NUCHealth.ps1 -ssh_user Administrator

param(
    [string]$nodes         = "nuc13-009,nuc13-010,nuc13-029",
    [string]$ssh_user      = "Administrator",
    [string]$domain_suffix = "wintest2.releng.mdc1.mozilla.com"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$target_shorts = @($nodes -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { ($_ -replace '\..*$', '').Trim() })
if ($target_shorts.Count -eq 0) { Write-Error "No nodes specified."; exit 1 }

# ------------------ Remote payload ------------------
# Returns one JSON object per node with all the diagnostic fields we want to diff.
$diagPayload = @"
`$ErrorActionPreference = 'Continue'

# --- Active power plan ---
`$pwrSchemeOut = & powercfg /getactivescheme 2>`$null
`$pwrPlan = if (`$pwrSchemeOut -match 'GUID:\s+([a-f0-9-]+)\s+\((.+)\)') { `$matches[2] } else { 'unknown' }
`$pwrGuid = if (`$pwrSchemeOut -match 'GUID:\s+([a-f0-9-]+)') { `$matches[1] } else { '' }

# Processor min/max state (sub_processor 893dee8e-2bef-41e0-89c6-b55d0929964c PROCTHROTTLEMIN/MAX)
function Get-PwrPctValue {
    param([string]`$Guid, [string]`$SubGuid, [string]`$SettingGuid)
    `$out = & powercfg /query `$Guid `$SubGuid `$SettingGuid 2>`$null
    `$line = `$out | Where-Object { `$_ -match 'Current AC Power Setting Index:\s+0x([0-9a-f]+)' } | Select-Object -First 1
    if (`$line -match '0x([0-9a-f]+)') { return [int]("0x" + `$matches[1]) }
    return `$null
}
`$procMin = Get-PwrPctValue -Guid `$pwrGuid -SubGuid '54533251-82be-4824-96c1-47b60b740d00' -SettingGuid '893dee8e-2bef-41e0-89c6-b55d0929964c'
`$procMax = Get-PwrPctValue -Guid `$pwrGuid -SubGuid '54533251-82be-4824-96c1-47b60b740d00' -SettingGuid 'bc5038f7-23e0-4960-96da-33abaf5935ec'

# --- CPU info ---
`$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
`$cpuName = `$cpu.Name
`$cpuMaxMHz = `$cpu.MaxClockSpeed
`$cpuCurMHz = `$cpu.CurrentClockSpeed
`$cpuCores = `$cpu.NumberOfCores
`$cpuLP = `$cpu.NumberOfLogicalProcessors

# --- Achieved %Performance under brief load ---
# Spin a short CPU burner on one logical core for 4s, sample %Processor Performance counter.
`$perfPctSamples = @()
`$burnerJob = Start-Job -ScriptBlock { `$end = (Get-Date).AddSeconds(5); while ((Get-Date) -lt `$end) { `$x = 0; for (`$i=0; `$i -lt 1000000; `$i++) { `$x = `$x + `$i } } }
Start-Sleep -Seconds 1
for (`$s = 0; `$s -lt 4; `$s++) {
    try {
        `$ctr = (Get-Counter '\Processor Information(_Total)\% Processor Performance' -ErrorAction Stop).CounterSamples[0].CookedValue
        `$perfPctSamples += [math]::Round(`$ctr, 1)
    } catch {}
    Start-Sleep -Milliseconds 800
}
Stop-Job `$burnerJob -ErrorAction SilentlyContinue
Remove-Job `$burnerJob -Force -ErrorAction SilentlyContinue
`$perfPctMax = if (`$perfPctSamples.Count -gt 0) { (`$perfPctSamples | Measure-Object -Maximum).Maximum } else { `$null }
`$perfPctSamplesStr = `$perfPctSamples -join ','

# --- RAM / DIMMs ---
`$ramDimms = @(Get-CimInstance Win32_PhysicalMemory)
`$ramTotalGB = [math]::Round((`$ramDimms | Measure-Object -Property Capacity -Sum).Sum / 1GB, 1)
`$ramSlots = `$ramDimms.Count
`$ramSpeeds = (`$ramDimms | ForEach-Object { `$_.ConfiguredClockSpeed } | Sort-Object -Unique) -join '/'
`$ramConfiguredSpeed = (`$ramDimms | ForEach-Object { `$_.ConfiguredClockSpeed } | Select-Object -First 1)
`$ramRatedSpeeds = (`$ramDimms | ForEach-Object { `$_.Speed } | Sort-Object -Unique) -join '/'
`$dimmDetail = (`$ramDimms | ForEach-Object {
    `$cap = [math]::Round(`$_.Capacity / 1GB, 0)
    `$loc = if (`$_.DeviceLocator) { `$_.DeviceLocator } else { 'slot?' }
    `$mfr = if (`$_.Manufacturer) { (`$_.Manufacturer -replace '\s+',' ').Trim() } else { '?' }
    `$pn  = if (`$_.PartNumber) { (`$_.PartNumber -replace '\s+',' ').Trim() } else { '?' }
    `$conf = if (`$_.ConfiguredClockSpeed) { `$_.ConfiguredClockSpeed } else { '?' }
    `$rated = if (`$_.Speed) { `$_.Speed } else { '?' }
    "`${loc}:`${cap}GB@`${conf}MHz(rated=`${rated}) `${mfr}/`${pn}"
}) -join ' | '

# --- Storage ---
`$disks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Sort-Object DeviceId)
`$diskDetail = (`$disks | ForEach-Object {
    `$sz = [math]::Round(`$_.Size / 1GB, 0)
    "`$(`$_.DeviceId):`$(`$_.MediaType)/`$(`$_.BusType) `$(`$_.Model) (`${sz}GB)"
}) -join ' | '

# --- BIOS ---
`$bios = Get-CimInstance Win32_BIOS
`$biosVer = `$bios.SMBIOSBIOSVersion
`$biosDate = if (`$bios.ReleaseDate) { (`$bios.ReleaseDate).ToString('yyyy-MM-dd') } else { '?' }
`$biosManufacturer = `$bios.Manufacturer

# --- OS ---
`$os = Get-CimInstance Win32_OperatingSystem
`$osBuild = `$os.BuildNumber
`$osVersion = `$os.Version
`$uptimeMin = [int]((Get-Date) - `$os.LastBootUpTime).TotalMinutes

# --- Top processes by CPU and by memory ---
`$procs = Get-Process | Where-Object { `$_.ProcessName -ne 'Idle' }
`$topCpu = (`$procs | Sort-Object CPU -Desc | Select-Object -First 5 | ForEach-Object { "`$(`$_.ProcessName)(CPU=`$([math]::Round(`$_.CPU,0))s)" }) -join ', '
`$topMem = (`$procs | Sort-Object WorkingSet64 -Desc | Select-Object -First 5 | ForEach-Object { "`$(`$_.ProcessName)(`$([math]::Round(`$_.WorkingSet64/1MB,0))MB)" }) -join ', '

# --- Worker / busy state ---
`$wsp = `$null
foreach (`$p in @("C:\WINDOWS\SystemTemp", `$env:TMP, `$env:TEMP, `$env:USERPROFILE)) {
    if (`$p) { `$c = Join-Path `$p "worker-status.json"; if (Test-Path `$c) { `$wsp = `$c; break } }
}
`$busy = `$false
if (`$wsp) {
    try { `$j = Get-Content `$wsp -Raw | ConvertFrom-Json; if (@(`$j.currentTaskIds).Count -gt 0) { `$busy = `$true } } catch {}
}

# --- Active interactive task user ---
`$taskUser = `$null
try {
    `$qu = & query user 2>`$null
    foreach (`$line in `$qu) {
        if (`$line -match '^\s*>?\s*(\S+)\s+\S+\s+(\d+)\s+Active') {
            `$u = `$matches[1]
            if (`$u -notmatch '^(Administrator|administrator|SYSTEM)$' -and `$u -ne `$env:USERNAME) {
                `$taskUser = `$u; break
            }
        }
    }
} catch {}

[pscustomobject]@{
    Hostname            = `$env:COMPUTERNAME
    Timestamp           = (Get-Date).ToString('s')
    PowerPlan           = `$pwrPlan
    ProcMinPct          = `$procMin
    ProcMaxPct          = `$procMax
    CPU                 = `$cpuName
    CPU_Cores           = `$cpuCores
    CPU_LogicalProcs    = `$cpuLP
    CPU_MaxMHz          = `$cpuMaxMHz
    CPU_CurMHz          = `$cpuCurMHz
    PerfPct_Samples     = `$perfPctSamplesStr
    PerfPct_Max         = `$perfPctMax
    RAM_GB              = `$ramTotalGB
    RAM_Slots           = `$ramSlots
    RAM_ConfiguredMHz   = `$ramConfiguredSpeed
    RAM_RatedMHz        = `$ramRatedSpeeds
    DIMM_Detail         = `$dimmDetail
    Disk_Detail         = `$diskDetail
    BIOS_Manufacturer   = `$biosManufacturer
    BIOS_Version        = `$biosVer
    BIOS_Date           = `$biosDate
    OS_Build            = `$osBuild
    OS_Version          = `$osVersion
    Uptime_Min          = `$uptimeMin
    Worker_Busy         = `$busy
    TaskUser            = `$taskUser
    Top_CPU             = `$topCpu
    Top_Mem             = `$topMem
} | ConvertTo-Json -Depth 5 -Compress
"@

# ------------------ Per-node diagnostic via scp + ssh -File ------------------
function Invoke-NodeDiag {
    param([string]$NodeName, [string]$User, [string]$Payload)

    $remoteName = "compare_nuchealth_$([guid]::NewGuid().ToString('N')).ps1"
    $localTemp  = Join-Path $env:TEMP $remoteName
    Set-Content -Path $localTemp -Value $Payload -Encoding UTF8

    try {
        $scpArgs = "-O -o ConnectTimeout=15 -o UserKnownHostsFile=NUL -o StrictHostKeyChecking=no `"$localTemp`" `"${User}@${NodeName}:$remoteName`""
        $psi = [System.Diagnostics.ProcessStartInfo]::new('scp')
        $psi.Arguments              = $scpArgs
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.CreateNoWindow         = $true
        $sp = [System.Diagnostics.Process]::Start($psi)
        $sp.StandardOutput.ReadToEnd() | Out-Null
        $scpErr = $sp.StandardError.ReadToEnd()
        $null = $sp.WaitForExit(60000)
        $scpExit = $sp.ExitCode
        $sp.Dispose()
        if ($scpExit -ne 0) {
            return [pscustomobject]@{ Node = $NodeName; Error = "scp failed (exit $scpExit): $scpErr"; Data = $null }
        }

        $remoteCmd = "powershell -NoLogo -NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"`$env:USERPROFILE\$remoteName`"; Remove-Item `"`$env:USERPROFILE\$remoteName`" -Force -ErrorAction SilentlyContinue"
        $sshArgs = "-o ConnectTimeout=15 -o UserKnownHostsFile=NUL -o StrictHostKeyChecking=no ${User}@${NodeName} $remoteCmd"
        $psi2 = [System.Diagnostics.ProcessStartInfo]::new('ssh')
        $psi2.Arguments              = $sshArgs
        $psi2.UseShellExecute        = $false
        $psi2.RedirectStandardOutput = $true
        $psi2.RedirectStandardError  = $true
        $psi2.CreateNoWindow         = $true
        $sp2 = [System.Diagnostics.Process]::Start($psi2)
        $stdout = $sp2.StandardOutput.ReadToEnd()
        $stderr = $sp2.StandardError.ReadToEnd()
        $null = $sp2.WaitForExit(120000)
        $sshExit = $sp2.ExitCode
        $sp2.Dispose()
        if ($sshExit -ne 0) {
            return [pscustomobject]@{ Node = $NodeName; Error = "ssh failed (exit $sshExit): $stderr"; Data = $null }
        }

        $jsonLine = ($stdout -split "`n") | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1
        if (-not $jsonLine) {
            return [pscustomobject]@{ Node = $NodeName; Error = "no JSON in stdout: $stdout"; Data = $null }
        }
        try {
            $obj = $jsonLine | ConvertFrom-Json
            return [pscustomobject]@{ Node = $NodeName; Error = $null; Data = $obj }
        } catch {
            return [pscustomobject]@{ Node = $NodeName; Error = "JSON parse: $_"; Data = $null }
        }
    } finally {
        Remove-Item $localTemp -Force -ErrorAction SilentlyContinue
    }
}

# ------------------ Run all nodes in parallel ------------------
Write-Host ""
Write-Host "------------------------------------------------------------"
Write-Host "  Compare-NUCHealth"
Write-Host "  Nodes: $($target_shorts -join ', ')"
Write-Host "  User : $ssh_user"
Write-Host "------------------------------------------------------------"
Write-Host ""
Write-Host "Collecting diagnostics (each node ~10-30s)..."
Write-Host ""

$rsPool = [RunspaceFactory]::CreateRunspacePool(1, $target_shorts.Count)
$rsPool.Open()
$jobs = [System.Collections.Generic.List[object]]::new()
foreach ($short in $target_shorts) {
    $fqdn = "$short.$domain_suffix"
    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $rsPool
    [void]$ps.AddScript(${function:Invoke-NodeDiag})
    [void]$ps.AddParameters(@{ NodeName = $fqdn; User = $ssh_user; Payload = $diagPayload })
    $jobs.Add([pscustomobject]@{ Short = $short; Fqdn = $fqdn; PS = $ps; Handle = $ps.BeginInvoke() })
}

$results = @{}
foreach ($job in $jobs) {
    try {
        $r = $job.PS.EndInvoke($job.Handle)[0]
    } catch {
        $r = [pscustomobject]@{ Node = $job.Fqdn; Error = "runspace: $_"; Data = $null }
    }
    $job.PS.Dispose()
    $results[$job.Short] = $r
    if ($r.Error) {
        Write-Host "[$($job.Short)] ERROR: $($r.Error)"
    } else {
        Write-Host "[$($job.Short)] ok"
    }
}
$rsPool.Close()
$rsPool.Dispose()

# ------------------ Side-by-side comparison table ------------------
$rows = @(
    'PowerPlan','ProcMinPct','ProcMaxPct','',
    'CPU','CPU_Cores','CPU_LogicalProcs','CPU_MaxMHz','CPU_CurMHz','PerfPct_Max','PerfPct_Samples','',
    'RAM_GB','RAM_Slots','RAM_ConfiguredMHz','RAM_RatedMHz','DIMM_Detail','',
    'Disk_Detail','',
    'BIOS_Manufacturer','BIOS_Version','BIOS_Date','',
    'OS_Build','OS_Version','Uptime_Min','',
    'Worker_Busy','TaskUser','',
    'Top_CPU','Top_Mem'
)

Write-Host ""
Write-Host "============================================================"
Write-Host "  COMPARISON"
Write-Host "============================================================"
Write-Host ""

$colNodes = $target_shorts
$labelWidth = ($rows | Where-Object { $_ } | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum + 2
$valueWidth = 50

# Header
$hdr = ("{0,-$labelWidth}" -f "metric")
foreach ($n in $colNodes) { $hdr += ("{0,-$valueWidth}" -f $n) }
Write-Host $hdr
Write-Host (("-" * $labelWidth) + (("-" * $valueWidth) * $colNodes.Count))

foreach ($field in $rows) {
    if (-not $field) { Write-Host ""; continue }
    $line = ("{0,-$labelWidth}" -f $field)
    foreach ($n in $colNodes) {
        $r = $results[$n]
        $v = if ($r -and $r.Data -and $r.Data.PSObject.Properties[$field]) {
            $val = $r.Data.$field
            if ($null -eq $val) { '<null>' } else { [string]$val }
        } else { '<no data>' }
        # Truncate long values for table display
        if ($v.Length -gt ($valueWidth - 2)) {
            $v = $v.Substring(0, $valueWidth - 5) + '...'
        }
        $line += ("{0,-$valueWidth}" -f $v)
    }
    Write-Host $line
}

# Also dump full JSON to a CSV-adjacent file for reference (long fields not truncated)
$stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
$outDir = "C:\logs"
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory $outDir -Force | Out-Null }
$outFile = Join-Path $outDir ("compare_nuchealth_{0}nodes_{1}.json" -f $colNodes.Count, $stamp)
$dump = @{}
foreach ($n in $colNodes) { $dump[$n] = if ($results[$n].Data) { $results[$n].Data } else { @{ Error = $results[$n].Error } } }
$dump | ConvertTo-Json -Depth 6 | Set-Content -Path $outFile -Encoding UTF8

Write-Host ""
Write-Host "Full data: $outFile"
