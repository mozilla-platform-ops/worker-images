<#
.SYNOPSIS
  On-VM build wrapper run as a scheduled task. Runs New-WinHwWim.ps1 to completion,
  tees output to a log, and writes a completion marker with the exit code so the
  workflow (on the GH runner) can poll for done/success without the ~90-min
  run-command limit applying to the build itself.

.DESCRIPTION
  Writes:
    C:\win-hw-wim-build\build.log   full build output (append-tee)
    C:\win-hw-wim-build\build.done  the exit code (0 = success) — created only when done
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Image,
    [string] $BuildId,
    # Optional New-WinHwWim -Stages (e.g. 'iso'). Blank = the default prep,build,publish bake.
    [string] $Stages,
    [string] $IdentityClientId,
    # Where to drop the completion marker the GH runner polls (see below). Defaults match
    # the pipeline's storage account / captured container.
    [string] $StatusAccount = 'hardwareimaging',
    [string] $StatusContainer = 'captured'
)
$base = 'C:\win-hw-wim-build'
New-Item -ItemType Directory -Path $base -Force | Out-Null
$log  = Join-Path $base 'build.log'
$done = Join-Path $base 'build.done'
Remove-Item $log, $done -ErrorAction SilentlyContinue

# Refresh PATH from the machine env so packer/az/azcopy/git resolve under the
# scheduled task (choco updated the machine PATH after the guest agent started).
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

# --- Live log streaming -------------------------------------------------------
# Without this the runner sees only "... building (N min elapsed)" for ~2h and then a
# 200-line tail at the END - and on a hang it sees NOTHING at all, because the job times
# out and the VM (with build.log on it) is destroyed. That blind spot is what made the
# post-bake windows-restart hang in run 31428853582 so expensive to diagnose. So push the
# WHOLE log to blob every minute; the runner prints each new chunk as it lands
# (ci/kickoff-win-hw-wim-build.ps1). Best-effort throughout: a failed upload must never
# affect the build, so every error here is swallowed and retried next cycle.
$liveBlob = "_status/$Image.live.log"
$liveJob = Start-Job -Name 'wim-live-log' -ScriptBlock {
    param($log, $account, $container, $blob, $clientId, $pathEnv)
    $env:Path = $pathEnv
    # Tee-Object holds build.log open for writing, so read it with FileShare::ReadWrite
    # and upload a snapshot - a plain Copy-Item/az on the live file hits a sharing violation.
    $snap = "$log.live"
    while ($true) {
        Start-Sleep -Seconds 60
        try {
            if (-not (Test-Path $log)) { continue }
            $in = [IO.File]::Open($log, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try {
                $out = [IO.File]::Create($snap)
                try { $in.CopyTo($out) } finally { $out.Dispose() }
            }
            finally { $in.Dispose() }
            # az may not be logged in yet on the first cycles (New-WinHwWim logs in itself).
            az account show 1>$null 2>$null
            if (($LASTEXITCODE -ne 0) -and $clientId) { az login --identity --client-id $clientId 1>$null 2>$null }
            az storage blob upload --account-name $account --container-name $container --name $blob --file $snap --overwrite --auth-mode login --only-show-errors 2>$null
        }
        catch {
            # Never let a streaming hiccup touch the build: log it into the snapshot's
            # sidecar (visible on the VM) and back off a cycle before trying again.
            "$([DateTime]::UtcNow.ToString('o')) live-log upload failed: $_" |
                Add-Content -Path "$snap.err" -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 30
        }
    }
} -ArgumentList $log, $StatusAccount, $StatusContainer, $liveBlob, $IdentityClientId, $env:Path

$nuc  = 'C:\worker-images\provisioners\windows\win-hw-wim\bin\WinHwWim\New-WinHwWim.ps1'
$rc = 0
try {
    $a = @('-Image', $Image)
    if ($BuildId) { $a += @('-BuildId', $BuildId) }
    if ($Stages) { $a += @('-Stages'); $a += ($Stages -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    if ($IdentityClientId) { $a += @('-IdentityClientId', $IdentityClientId) }
    # Run in a child process so we get a reliable exit code (New-WinHwWim uses -EA Stop).
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $nuc @a *>&1 | Tee-Object -FilePath $log
    $rc = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
}
catch {
    $rc = 1
    $_ | Out-String | Add-Content -Path $log
}
if ($liveJob) { Stop-Job $liveJob -ErrorAction SilentlyContinue; Remove-Job $liveJob -Force -ErrorAction SilentlyContinue }
Set-Content -Path $done -Value $rc

# --- Signal completion to the GH runner via BLOB storage ----------------------
# The runner used to detect completion by polling this build.done over
# `az vm run-command`, but that extension WEDGES under the bake's heavy nested-virt
# load and left finished builds undetected (the job hung ~2h). Uploading a marker the
# runner reads with its OWN az (ci/kickoff-win-hw-wim-build.ps1) is immune to that.
# az is normally already logged in as the UAMI (New-WinHwWim), but log in defensively so
# we can ALWAYS signal - including on an early New-WinHwWim failure before its own login.
try {
    if ($IdentityClientId) {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        az account show 1>$null 2>$null
        if ($LASTEXITCODE -ne 0) { az login --identity --client-id $IdentityClientId 1>$null 2>$null }
        $ErrorActionPreference = $prevEap
    }
    # FINAL live-log push before the marker: the last streaming cycle can be up to a minute
    # behind, and the interesting part of a failure is always the last few lines. Uploaded
    # before .done so the runner's closing delta is complete the moment it sees the marker.
    az storage blob upload --account-name $StatusAccount --container-name $StatusContainer --name $liveBlob --file $log --overwrite --auth-mode login --only-show-errors 2>$null
    # A tail of the build log for visibility (uploaded first, so it's present when 'done' appears).
    $statusLog = Join-Path $base 'status.log'
    Get-Content $log -Tail 200 -ErrorAction SilentlyContinue | Set-Content -Path $statusLog -Encoding utf8
    az storage blob upload --account-name $StatusAccount --container-name $StatusContainer --name "_status/$Image.log" --file $statusLog --overwrite --auth-mode login --only-show-errors 2>$null
    # Authoritative marker LAST, with a small retry (its content is the exit code).
    for ($u = 1; $u -le 3; $u++) {
        az storage blob upload --account-name $StatusAccount --container-name $StatusContainer --name "_status/$Image.done" --file $done --overwrite --auth-mode login --only-show-errors 2>$null
        if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep -Seconds 10
    }
}
catch {
    $_ | Out-String | Add-Content -Path $log
}
