# CleanupSP3.ps1
# Resets per-node state left behind by aborted/timed-out StressSP3 runs.
# Default targets the 3-node compare set; override with -nodes "a,b,c".
#
# What it does on each node (via SSH as Administrator):
#   - kills any leftover firefox.exe
#   - stops any active xperf NT Kernel Logger session
#   - stops any leftover logman trace whose name starts with StressProcPower_
#   - unregisters any scheduled task named StressSP3_FF_*
#   - deletes stress_payload_*.ps1 from the Administrator home dir
#   - deletes the C:\Users\Public\sp3stress workdir
#
# Usage:
#   .\CleanupSP3.ps1                                    # cleans nuc13-009, -010, -029
#   .\CleanupSP3.ps1 -nodes "nuc13-029"                 # one node
#   .\CleanupSP3.ps1 -nodes "nuc13-029,nuc13-010"       # custom list
#   .\CleanupSP3.ps1 -ssh_user Administrator            # override login user

param(
    [string]$nodes    = "nuc13-009,nuc13-010,nuc13-029",
    [string]$ssh_user = "Administrator",
    [string]$domain_suffix = "wintest2.releng.mdc1.mozilla.com"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$target_shorts = @($nodes -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { ($_ -replace '\..*$', '').Trim() })
if ($target_shorts.Count -eq 0) { Write-Error "No nodes specified."; exit 1 }

$cleanup = @'
$ErrorActionPreference = 'SilentlyContinue'
Get-Process firefox -EA 0 | Stop-Process -Force -EA 0
& xperf -stop 2>$null | Out-Null
logman query -ets 2>$null | Select-String StressProcPower_ | ForEach-Object {
    $name = ($_.Line -split '\s+')[0]
    & logman stop $name -ets 2>$null | Out-Null
}
Get-ScheduledTask -TaskName 'StressSP3_FF_*' -EA 0 | Unregister-ScheduledTask -Confirm:$false -EA 0
Remove-Item 'C:\Users\Administrator\stress_payload_*.ps1' -Force -EA 0
Remove-Item 'C:\Users\Public\sp3stress' -Recurse -Force -EA 0
Write-Host "cleaned $env:COMPUTERNAME"
'@

Write-Host ""
Write-Host "------------------------------------------------------------"
Write-Host "  CleanupSP3 - resetting per-node state"
Write-Host "  Nodes: $($target_shorts -join ', ')"
Write-Host "  User : $ssh_user"
Write-Host "------------------------------------------------------------"
Write-Host ""

$failed = @()
foreach ($short in $target_shorts) {
    $fqdn = "$short.$domain_suffix"
    Write-Host "--- $fqdn ---"
    try {
        & ssh -o ConnectTimeout=15 -o UserKnownHostsFile=NUL -o StrictHostKeyChecking=no `
            "$ssh_user@$fqdn" "powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $cleanup"
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  SSH exit code: $LASTEXITCODE"
            $failed += $fqdn
        }
    } catch {
        Write-Host "  Error: $($_.Exception.Message)"
        $failed += $fqdn
    }
    Write-Host ""
}

Write-Host "==== DONE ===="
if ($failed.Count -gt 0) {
    Write-Host "Failed:"
    $failed | ForEach-Object { Write-Host "  - $_" }
    exit 1
}
Write-Host "All nodes cleaned."
