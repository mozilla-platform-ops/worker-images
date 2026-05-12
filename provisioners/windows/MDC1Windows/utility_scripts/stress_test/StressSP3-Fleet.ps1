# StressSP3-Fleet.ps1
# Fleet-wide SP3 stress test wrapper around StressSP3.ps1.
#
# What this is for: run the validated Speedometer 3 + Marionette + ETW workload
# from StressSP3.ps1 against every NUC13 in the fleet (default range 1..160),
# with the same retry / busy-skip / skip-list semantics StressCPU.ps1 uses for
# the prime95 fleet sweeps. Used in RELOPS-2323 to score every node under a
# realistic CI workload after the 2026-05-07 Perf_Max scan identified the
# suspected service candidates.
#
# Behavior:
#   - Builds a node list by expanding nuc13-NNN across [-range_start..-range_end]
#     OR explicit -nodes "a,b,c" OR -single -node nuc13-XXX.
#   - Filters out known-bad PSU / deployment-failure nodes (same skip list as
#     StressCPU.ps1) unless -no_skip is passed.
#   - Forwards every SP3-specific switch (loops, iterations, duration, etc.)
#     verbatim to StressSP3.ps1 along with the expanded node list.
#   - StressSP3.ps1 already implements: 3-pass SSH retry, busy-skip with retry
#     pass, parallel execution per max_parallel, busy detection via
#     worker-status.json, scp+ssh-File transport as Administrator. We rely on
#     all of that and just feed it a fleet-scale node list.
#
# Usage:
#   .\StressSP3-Fleet.ps1                                    # default 1..160 sweep, 1 SP3 loop, 600s cap
#   .\StressSP3-Fleet.ps1 -sp3_loops 9 -duration_secs 600    # ~10-min CI-like run per node
#   .\StressSP3-Fleet.ps1 -range_start 1 -range_end 50       # subset
#   .\StressSP3-Fleet.ps1 -nodes "nuc13-077,nuc13-079"       # explicit list
#   .\StressSP3-Fleet.ps1 -single -node nuc13-029            # one node
#   .\StressSP3-Fleet.ps1 -dry_run                           # show targets, do not execute
#   .\StressSP3-Fleet.ps1 -no_skip                           # disable the PSU-skip filter
#
# Output is whatever StressSP3.ps1 produces: CSV + transcript log in
# $output_dir (default C:\logs).

param(
    # Range mode (default)
    [int]$range_start      = 1,
    [int]$range_end        = 160,
    [int]$range_pad        = 3,
    [string]$range_prefix  = "nuc13",

    # Explicit overrides (bypass range)
    [string]$nodes         = "",
    [switch]$single,
    [string]$node          = "",

    # SSH / transport (forwarded)
    [string]$ssh_user      = "Administrator",
    [int]$ssh_max_retries  = 3,
    [int]$retry_sleep_secs = 120,
    [int]$max_parallel     = 3,

    # SP3 workload (forwarded)
    [int]$duration_secs    = 600,
    [int]$sp3_loops        = 1,
    [int]$sp3_iterations   = 10,
    [switch]$visible,
    [switch]$test_remote,
    [switch]$quick,

    # Skip list / dry-run / retry control
    [switch]$no_skip,
    [switch]$dry_run,
    [switch]$no_retry,

    [string]$output_dir    = "C:\logs"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ------------------ Skip list (matches StressCPU.ps1) ------------------
$skip_nodes = @(
    "nuc13-035","nuc13-036","nuc13-059","nuc13-060","nuc13-061",
    "nuc13-068","nuc13-070","nuc13-075","nuc13-096","nuc13-112",
    "nuc13-130","nuc13-149","nuc13-154","nuc13-155","nuc13-156","nuc13-157",
    "nuc13-107","nuc13-150"
)

# ------------------ Resolve target node list ------------------
$target_shorts = @()
if ($single) {
    if (-not $node) { Write-Error "-node is required with -single"; exit 1 }
    $target_shorts = @(($node -replace '\..*$', '').Trim())
}
elseif ($nodes) {
    $target_shorts = @($nodes -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { ($_ -replace '\..*$', '').Trim() })
}
else {
    # Range mode (default)
    $target_shorts = $range_start..$range_end | ForEach-Object {
        "{0}-{1:D$range_pad}" -f $range_prefix, $_
    }
}

# Apply skip list
if (-not $no_skip -and -not $single) {
    $before = $target_shorts.Count
    $hit = @($target_shorts | Where-Object { $skip_nodes -contains $_ })
    $target_shorts = @($target_shorts | Where-Object { $skip_nodes -notcontains $_ })
    if ($hit.Count -gt 0) {
        Write-Host "Skipping $($hit.Count) known-problem node(s): $($hit -join ', ')" -ForegroundColor Yellow
    }
}

if ($target_shorts.Count -eq 0) { Write-Error "No nodes to scan."; exit 1 }

Write-Host ""
Write-Host "------------------------------------------------------------"
Write-Host "  StressSP3-Fleet wrapper"
Write-Host "  Targets    : $($target_shorts.Count) node(s)"
Write-Host "  Range      : $range_start..$range_end (skip list active: $(-not $no_skip))"
Write-Host "  SP3 loops  : $sp3_loops"
Write-Host "  Iterations : $sp3_iterations"
Write-Host "  Per-node   : up to $duration_secs s"
Write-Host "  Parallel   : $max_parallel"
Write-Host "  Visible    : $visible"
Write-Host "  Dry run    : $dry_run"
Write-Host "------------------------------------------------------------"
Write-Host ""

# ------------------ Forward to StressSP3.ps1 ------------------
$sp3Path = Join-Path $PSScriptRoot "StressSP3.ps1"
if (-not (Test-Path $sp3Path)) {
    Write-Error "StressSP3.ps1 not found at $sp3Path"
    exit 1
}

# Build argument hashtable. StressSP3.ps1 takes -nodes as a string.
$nodesArg = $target_shorts -join ","

$invokeArgs = @{
    nodes              = $nodesArg
    ssh_user           = $ssh_user
    ssh_max_retries    = $ssh_max_retries
    retry_sleep_secs   = $retry_sleep_secs
    max_parallel       = $max_parallel
    duration_secs      = $duration_secs
    sp3_loops          = $sp3_loops
    sp3_iterations     = $sp3_iterations
    output_dir         = $output_dir
}
if ($visible)     { $invokeArgs.visible     = $true }
if ($test_remote) { $invokeArgs.test_remote = $true }
if ($quick)       { $invokeArgs.quick       = $true }
if ($dry_run)     { $invokeArgs.dry_run     = $true }
if ($no_retry)    { $invokeArgs.no_retry    = $true }

# Splat into the underlying script
& $sp3Path @invokeArgs
