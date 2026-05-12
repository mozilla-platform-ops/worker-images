# MDC1 Windows NUC stress-test toolkit

PowerShell harness for stress-testing, characterizing, and cleaning up after
workload runs on the wintest2 NUC13 fleet
(`*.wintest2.releng.mdc1.mozilla.com`).

Built during the [RELOPS-2323](https://mozilla-hub.atlassian.net/browse/RELOPS-2323)
throttling / perf-degrade investigation in April-May 2026. Latest versions
of the scripts attached to that ticket as of 2026-05-08.

All scripts are designed to be run from a Windows host with `ssh.exe` and
`scp.exe` on `PATH` (the Windows OpenSSH client) and an SSH key authorized
on the target NUCs as `Administrator`. CSVs / transcripts default to
`C:\logs\` on the driver machine.

## Shared architecture

Every script that hits the fleet uses the same orchestration pattern:

1. Build a self-contained PowerShell diagnostic payload as a here-string,
   with the **local** variables (e.g. `$duration_secs`) baked in at
   construction time and **remote** variables backtick-escaped.
2. Ship the payload via `scp` to the target node's Administrator home dir
   (avoids the cmd.exe 8191-char limit on `-EncodedCommand`).
3. Invoke it via `ssh powershell -File <path>`.
4. Parse one JSON line out of stdout (`Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1`).

Parallelism uses `[RunspaceFactory]::CreateRunspacePool` (not `Start-Job` -
spawning a child `powershell.exe` per node costs 5-15s on a cold-cache node).
Log lines from runspaces drain through a `ConcurrentQueue[string]` so output
stays interleaved cleanly.

A "busy gate" reads `worker-status.json` on each node before doing anything
destructive - if `currentTaskIds.Count > 0`, the node is skipped so a live CI
task isn't disturbed.

Retries: 3 sequential SSH retry passes with a 120s sleep between, only on
nodes that failed (successful nodes don't re-run). Busy-retry passes are
separate and also bounded.

A shared **skip list** of known-bad PSU / persistent-SSH-failure /
deployment-failure nodes is duplicated across the fleet scripts to avoid
wasting cycles on hardware that won't respond. Today the list lives inline
in each script; if you change it in one place change it everywhere.

## Scripts

### `StressSP3.ps1` - SP3 + Marionette + ETW workload (1150 lines)

The flagship workload. Drives a real Speedometer 3.1 run against Firefox via
the Marionette protocol over TCP 2828, while capturing ETW power-management
events. This is what the RELOPS-2323 5-loop fleet sweep used to score every
node against CI-equivalent load.

Per-node, the remote payload:

1. Self-heals leftover state from any abandoned prior run (kill firefox,
   stop xperf, unregister `StressSP3_FF_*` scheduled tasks, wipe the
   workdir). Runs only after the busy gate so a live task is never touched.
2. Starts an xperf kernel trace (`PROC_THREAD+LOADER+POWER`) and a logman
   user-mode trace on `Microsoft-Windows-Kernel-Processor-Power`.
3. Installs Firefox via Chocolatey if not already present (and uninstalls
   it at the end if-and-only-if this run installed it).
4. Detects the active interactive user via `query user` and launches
   Firefox **as that user** through a one-shot scheduled task
   (`LogonType=Interactive` reuses the existing logon token - no password
   required). Falls back to Start-Process as Administrator if no task
   user is logged in.
5. Runs a hand-rolled Marionette client (Python here-string) that
   navigates to `https://browserbench.org/Speedometer3.1/`, starts the
   benchmark, and polls the DOM for `#result-number` / `.score-value` /
   etc. Loops `-sp3_loops` times in the same Firefox to approximate
   CI's ~10-min Browsertime cycle window.
6. Stops ETW, parses the user-mode ETL with `Get-WinEvent -FilterXPath`
   (FilterXPath is load-bearing - reading all events from a 12-loop ETL
   would take 10+ min and time out the SSH session).
7. Runs `xperf -i kernel.etl -a cpufreq` for a frequency-residency summary.
8. Returns one JSON line with per-loop scores, throttling counters, CPU
   samples, Firefox launch mode, ETW event counts, and metadata.

Default mode is a 20-node "May 2026 perf-anomaly list" baked into the
script. Override with `-nodes "a,b,c"`, `-single -node X`, or splat from
`StressSP3-Fleet.ps1` for a fleet sweep.

### `StressSP3-Fleet.ps1` - fleet-wide SP3 wrapper (150 lines)

Thin wrapper over `StressSP3.ps1` that expands a node range
(default 1..160), explicit list, or single node, applies the shared skip
list, and splats forwarded args into `StressSP3.ps1`. All retry / parallel
/ busy-skip logic lives in the underlying StressSP3 script.

This is the script that produced the 5-loop fleet sweep data
(`-sp3_loops 5`) referenced in RELOPS-2323 comment 1420888.

Typical invocations:

```powershell
.\StressSP3-Fleet.ps1                                    # 1-loop sweep, 1..160
.\StressSP3-Fleet.ps1 -sp3_loops 3 -duration_secs 600    # monthly cadence (~45 min)
.\StressSP3-Fleet.ps1 -sp3_loops 5                       # degrade-over-loops detection (~75 min)
.\StressSP3-Fleet.ps1 -range_start 1 -range_end 50       # subset
.\StressSP3-Fleet.ps1 -nodes "nuc13-077,nuc13-079"       # explicit
```

### `StressCPU.ps1` - prime95 torture-mode CPU stress (727 lines)

Older heavyweight CPU stress test, complement to the SP3 workload. Runs
prime95 (`-t` torture mode) for `-duration_secs` per node and captures:

- `% Processor Time` (utilization) min/max/avg + raw samples
- `% Processor Performance` (achieved frequency, >100=turbo, <100=below
  nominal - the silicon-throttle fingerprint that pure CPU% can't see)
- `Microsoft-Windows-Kernel-Processor-Power` Ev37 (firmware CPU limiting)
  and Ev55 (perf state) events that fired during the stress window
- prime95 self-test pass/fail counts to detect mid-run instability

Four input modes: `-single -node X`, `-list -nodes a,b,c`,
`-range -range_start N -range_end M`, `-pool -pool_name <name>`. Pool mode
pulls `pools.yml` from this repo's `main` branch raw URL.

Downloads prime95 to `C:\prime95\` on the target node if not already
present. Configures `prime.txt` for all logical cores, FFT range 4-8192,
hyperthreading on.

### `Scan-NUCHealth.ps1` - fast 10-min triage burner (459 lines)

Per-node ~10-sec single-thread CPU burner sampling
`% Processor Performance` every second. Captures the brief
turbo-headroom signature that prompted RELOPS-2323. Per-node fields:

- `Perf_Min/Max/Avg` (full window)
- `Perf_LateAvg/LateMin` (last 4 samples - exposes thermal/PSU collapse
  that doesn't show in `Perf_Max`)
- Power plan, BIOS version/date, CPU base MHz, RAM total, OS build, uptime

Default sweep is 1..160 with the shared skip list applied. 3-pass SSH
retry. Output: CSV + JSON + transcript in `C:\logs\`, plus a sorted-by-
lowest-`Perf_Max` console table for triage.

**Recommended cadence:** daily or weekly. The full sweep finishes in
about 10 min at the default `max_parallel=8`. Per the RELOPS-2323
analysis, this scan is good triage (catches stuck-low / clear no-turbo)
but its `r=0.48` correlation with CI Speedometer3 is far weaker than a
multi-loop StressSP3 sweep (`r=0.84`). Use it for fast scans; use SP3
for actual workload-tier decisions.

### `Compare-NUCHealth.ps1` - side-by-side diff harness (334 lines)

Pinpoint hardware/firmware/software comparison across a small set of
nodes (defaults to the 3-node SP3 throttling compare set:
nuc13-009 / 010 / 029). Returns a side-by-side table on stdout plus a
full JSON dump in `C:\logs\compare_nuchealth_*.json`.

Captures per-DIMM detail (location, capacity, manufacturer, part number,
configured vs rated MHz), per-disk media-type/bus/model, power plan +
processor min/max state, BIOS version/manufacturer/date, OS build,
uptime, the active interactive task user, and the top 5 processes by
CPU and working set. Also runs a brief CPU-burner perf sample for
side-by-side `Perf_Max` comparison.

Use this when you need to ask "what is structurally different between
this good node and this bad node?"

### `CleanupSP3.ps1` - per-node state reset (77 lines)

Resets state left behind by aborted / timed-out StressSP3 runs. Per
target node (via SSH as Administrator):

- kills any leftover `firefox.exe`
- stops any active xperf NT Kernel Logger session
- stops any leftover logman trace whose name starts with
  `StressProcPower_`
- unregisters any scheduled task named `StressSP3_FF_*`
- deletes `stress_payload_*.ps1` from `C:\Users\Administrator\`
- deletes the `C:\Users\Public\sp3stress` workdir

Defaults to the 3-node compare set; override with `-nodes "a,b,c"`.

Run this before any new StressSP3 invocation if a previous run was
killed mid-flight (SSH timeout, Ctrl-C, host reboot). StressSP3 also
self-heals at the start of each run, but only after its busy gate -
`CleanupSP3` is the unconditional reset.

### `UninstallFirefox.ps1` - fleet-wide Firefox cleanup (459 lines)

Walks the fleet and uninstalls Firefox installs that StressSP3 may have
left behind. The default is conservative: only uninstalls Firefox if
Chocolatey reports it as a managed package
(`choco list --local-only firefox`). If Firefox was installed by puppet
or by the base image, `choco` won't claim it and this script leaves it
alone. Pass `-force` to uninstall regardless.

Why this is needed: StressSP3 installs Firefox via choco only if
firefox.exe isn't already present, and only uninstalls on the same run
if that install succeeded. If a run is killed before the uninstall step,
Firefox can be left installed on the node.

Action matrix: `dry_run` / `absent` / `skipped_not_choco_managed` /
`skipped_no_choco` / `uninstalled` / `uninstall_failed`. CSV +
JSON + transcript output to `C:\logs\uninstall_firefox_*`.

## Recommended cadence (from RELOPS-2323 analysis 2026-05-08)

1. **`Scan-NUCHealth.ps1`** - daily / weekly. Fast (~10 min). Triage only.
2. **`StressSP3-Fleet.ps1 -sp3_loops 3`** - monthly, or after each batch
   of physical hardware service. Best CI predictor we have
   (`r=0.84` vs CI Speedometer3). ~45 min wall-clock at `max_parallel=3`.
3. Reserve **`-sp3_loops 5`** (or higher) for runs where you specifically
   want to expose degrade-over-loops patterns (the kind that caught
   nuc13-129 / 131 as thermal degraders that the burner and CI both
   averaged away).

## Outputs

All scripts write to `C:\logs\` on the driver machine by default. Common
filename patterns:

| Script                     | Files                                              |
| -------------------------- | -------------------------------------------------- |
| `Scan-NUCHealth.ps1`       | `fleet_scan_<N>nodes_<stamp>.{csv,json,log}`       |
| `StressCPU.ps1`            | `cpu_stress_<tag>_<stamp>.{csv,log}`               |
| `StressSP3.ps1` (+ fleet)  | `stress_sp3_list-<N>nodes_<stamp>.{csv,log}`       |
| `Compare-NUCHealth.ps1`    | `compare_nuchealth_<N>nodes_<stamp>.json`          |
| `UninstallFirefox.ps1`     | `uninstall_firefox_<N>nodes_<stamp>.{csv,json,log}`|
