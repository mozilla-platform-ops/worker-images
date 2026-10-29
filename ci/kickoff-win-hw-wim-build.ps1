<#
.SYNOPSIS
  Run a Windows HW WIM build on the ephemeral Azure build VM and WAIT for it. Runs on
  the GitHub Actions runner (pwsh + az, already authenticated by azure/login).

.DESCRIPTION
  The build needs nested Hyper-V (can't run on the GH-hosted runner) and exceeds the
  ~90-min az vm run-command limit, so this:
    1. has the VM check out worker-images at PIPELINE_SHA and launch the build as a
       detached scheduled task (provisioners/.../scripts/run-build-task.ps1, which
       writes C:\win-hw-wim-build\build.done with the exit code when finished), then
    2. polls that marker until the build finishes, streaming the tail of the log,
    3. exits with the build's result so the workflow job passes/fails accordingly.

  The workflow creates the VM before this step and destroys it after (if: always()).

  Env (set by the workflow):
    IMAGE, PIPELINE_SHA, BUILD_ID (optional), GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT, VM_NAME, RESOURCE_GROUP
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$image   = $env:IMAGE;        if (-not $image) { throw 'IMAGE not set' }
$checkoutRevision = (git rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $checkoutRevision -notmatch '^[0-9a-fA-F]{40}$') { throw 'Invalid runner checkout revision.' }
# Older workflow dispatchers do not pass PIPELINE_SHA.
$revision = if ($env:PIPELINE_SHA) { $env:PIPELINE_SHA } else { $checkoutRevision }
if ($revision -notmatch '^[0-9a-fA-F]{40}$') { throw 'PIPELINE_SHA must be a full commit SHA.' }
if ($checkoutRevision -ne $revision) { throw 'Runner checkout does not match PIPELINE_SHA.' }
$buildId = $env:BUILD_ID
$stages  = $env:STAGES        # blank = default prep,build,publish bake; e.g. 'iso' for the ISO stage
$vm      = if ($env:VM_NAME) { $env:VM_NAME } else { 'win-hw-wim-builder' }
$rg      = if ($env:RESOURCE_GROUP) { $env:RESOURCE_GROUP } else { 'rg-central-us-hardware-imaging' }

# Inputs flow into a remote script — allow only safe characters.
if ($image -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw 'Illegal IMAGE.' }
if ($buildId -and $buildId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Illegal BUILD_ID: '$buildId'" }
if ($stages -and $stages -notmatch '^[A-Za-z,]+$') { throw "Illegal STAGES: '$stages'" }

$runId = $env:GITHUB_RUN_ID
$attempt = $env:GITHUB_RUN_ATTEMPT
if ($runId) {
    if ($runId -notmatch '^[0-9]+$' -or $attempt -notmatch '^[1-9][0-9]*$') { throw 'Invalid workflow run identity.' }
} else {
    $runId = 'manual-' + [guid]::NewGuid().ToString('N')
    $attempt = '1'
}
$buildId = if ($buildId) { "$buildId-$runId-$attempt" } else { "$runId-$attempt" }
$statusPrefix = "_status/$image/$runId/$attempt"
$buildArg = "-BuildId $buildId -StatusPrefix $statusPrefix -PipelineRevision $revision"
if ($stages) { $buildArg = "$buildArg -Stages $stages" }

# The build VM has only a USER-assigned managed identity, so New-WinHwWim must log in
# with `az login --identity --username <clientId>`. Resolve that client id here (this
# runner is az-authenticated via OIDC) and pass it through to the build.
$idName = if ($env:BUILDER_IDENTITY_NAME) { $env:BUILDER_IDENTITY_NAME } else { 'id-central-us-hardware-imaging-builder' }
$idClientId = (az identity show -g $rg -n $idName --query clientId -o tsv 2>$null)
if ($idClientId) { $buildArg = "$buildArg -IdentityClientId $idClientId".Trim() }
else { Write-Warning "Could not resolve client id for identity '$idName' in '$rg'; build may fail to az login." }

# Each run attempt owns its completion marker and logs.
$stAccount   = 'hardwareimaging'
$stContainer = 'captured'

# --- OIDC re-auth setup -------------------------------------------------------
# azure/login's Azure token lasts ~1h and can't be refreshed, but this step waits ~2h
# for the bake. Capture our identity NOW (token still fresh) so we can re-login with a
# fresh GitHub OIDC token during the poll (ci/az-relogin.ps1) and keep the blob poll
# authenticated. Not doing this is what hid the finished build for 4h (expired-token
# downloads failed silently -> the .done marker was never read -> 240-min timeout).
$reloginScript = Join-Path $PSScriptRoot 'az-relogin.ps1'
$acctNow    = az account show -o json 2>$null | ConvertFrom-Json
$azClientId = if ($acctNow) { $acctNow.user.name } else { $null }
$azTenantId = if ($acctNow) { $acctNow.tenantId } else { $null }
$azSubId    = if ($acctNow) { $acctNow.id }        else { $null }
function Invoke-AzRelogin {
    try { & $reloginScript -ClientId $azClientId -TenantId $azTenantId -SubscriptionId $azSubId }
    catch { Write-Warning "az OIDC re-login failed (will retry next interval): $_" }
}

# --- Start the build (checkout repo + register/start the scheduled task) -------
$start = @"
`$ErrorActionPreference = 'Stop'
# Refresh PATH from the machine env — tools installed by choco after the guest agent
# started (no reboot since) aren't on this run-command's inherited PATH otherwise.
`$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
`$repo = 'C:\worker-images'
if (-not (Test-Path (Join-Path `$repo '.git'))) {
    git init `$repo
    if (`$LASTEXITCODE -ne 0) { throw 'git init failed' }
    git -C `$repo remote add origin https://github.com/mozilla-platform-ops/worker-images.git
    if (`$LASTEXITCODE -ne 0) { throw 'git remote add failed' }
}
git -C `$repo fetch --depth=1 origin '$revision'
if (`$LASTEXITCODE -ne 0) { throw 'Pipeline commit fetch failed' }
git -C `$repo checkout --detach --force '$revision'
if (`$LASTEXITCODE -ne 0) { throw 'Pipeline checkout failed' }
`$actual = (git -C `$repo rev-parse HEAD).Trim()
if (`$LASTEXITCODE -ne 0 -or `$actual -ne '$revision') { throw 'Builder checkout does not match pipeline revision' }
if (-not (Test-Path (Join-Path `$repo 'provisioners\windows\win-hw-wim\scripts\run-build-task.ps1'))) { throw 'repo checkout missing run-build-task.ps1' }
`$task = Join-Path `$repo 'provisioners\windows\win-hw-wim\scripts\run-build-task.ps1'
`$arg  = "-NoProfile -ExecutionPolicy Bypass -File ""`$task"" -Image $image $buildArg"
`$act  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument `$arg
Register-ScheduledTask -TaskName 'win-hw-wim-build' -Action `$act -RunLevel Highest -User 'SYSTEM' -Force | Out-Null
Start-ScheduledTask -TaskName 'win-hw-wim-build'
Write-Output 'KICKOFF_OK'
"@

$kickoffUtc = (Get-Date).ToUniversalTime()
Write-Host "== Starting build '$image' (commit '$revision', build '$buildId', status '$statusPrefix') on $vm (kickoff $($kickoffUtc.ToString('o'))) =="
$out = az vm run-command invoke -g $rg -n $vm --command-id RunPowerShellScript --scripts "$start" --query "join('`n', value[].message)" -o tsv
Write-Host $out
# az vm run-command returns 0 even if the inner script threw — assert the sentinel so a
# failed checkout/register fails fast instead of polling a build that never started.
if ("$out" -notmatch '(?m)^KICKOFF_OK\s*$') { throw "Failed to start the build on $vm (no KICKOFF_OK):`n$out" }

# --- Poll the completion marker (from blob, NOT run-command) -------------------
# Poll only this run attempt.
$intervalSec = 60
$maxMinutes  = 240   # hard cap; a real bake is ~90-150 min (windows_update=true images
                     # sit at the top of that range, and their two windows-restart
                     # provisioners may each burn up to 60m). The poll stays
                     # authenticated (OIDC re-login below), so hitting this means a
                     # genuinely stuck build - not a monitoring blind spot as before.
$reloginEverySec = 1200   # re-auth every ~20 min so the ~1h azure/login token never lapses
$rc = $null
$doneName = "$statusPrefix/build.done"
$doneTmp  = Join-Path ([IO.Path]::GetTempPath()) "bake-$buildId.done"

# --- Live log streaming -------------------------------------------------------
# Two append-only logs are pushed to blob during the build and tailed here, so the GH job
# follows the bake in real time instead of getting a 200-line tail two hours later - and
# gets nothing at all when a hang runs the job into its timeout and the VM is destroyed:
#   <image>.live.log      the whole build.log (packer, puppet, capture, publish)
#   <image>.watchdog.log  the host-side boot watchdog, incl. its PowerShell Direct capture
#                         of the GUEST's event log when a step stalls. PS Direct goes over
#                         the Hyper-V VMBus, so it still works when the guest's network and
#                         WinRM are dead - which is exactly when packer goes blind and we
#                         have historically had no idea what the guest was doing.
# Each stream prints only lines not yet printed; a per-blob counter tracks how far we got.
$streams = [ordered]@{
    "$statusPrefix/build.live.log"     = ''
    "$statusPrefix/build.watchdog.log" = '  [guest] '
}
$streamPrinted = @{}
foreach ($k in $streams.Keys) { $streamPrinted[$k] = 0 }

function Show-LogDelta {
    param([string] $BlobName, [string] $Prefix)

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("bake-" + ($BlobName -replace '[\\/:]', '-'))
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    az storage blob download --account-name $stAccount --container-name $stContainer --name $BlobName --file $tmp --auth-mode login --only-show-errors -o none 2>$null
    if (-not (Test-Path $tmp)) { return }
    $lines = @(Get-Content $tmp -ErrorAction SilentlyContinue)
    $seen = $script:streamPrinted[$BlobName]
    if ($lines.Count -le $seen) { return }
    $lines[$seen..($lines.Count - 1)] | ForEach-Object { Write-Host ($Prefix + $_) }
    $script:streamPrinted[$BlobName] = $lines.Count
}

function Show-AllLogDeltas {
    foreach ($k in $streams.Keys) { Show-LogDelta -BlobName $k -Prefix $streams[$k] }
}

for ($elapsed = 0; $elapsed -lt ($maxMinutes * 60); $elapsed += $intervalSec) {
    Start-Sleep -Seconds $intervalSec
    # Refresh the Azure token before it can expire (azure/login's lasts ~1h; bake ~2h).
    if (($elapsed % $reloginEverySec) -eq 0) { Invoke-AzRelogin }
    Remove-Item $doneTmp -Force -ErrorAction SilentlyContinue
    $downloadOut = az storage blob download --account-name $stAccount --container-name $stContainer --name $doneName --file $doneTmp --auth-mode login --only-show-errors -o none 2>&1
    $downloadRc = $LASTEXITCODE
    if ($downloadRc -eq 0 -and (Test-Path -LiteralPath $doneTmp)) {
        $rc = [int]((Get-Content $doneTmp -Raw).Trim())
        break
    }
    if ($downloadRc -ne 0 -and "$downloadOut" -notmatch '(?i)not\s*found|does not exist|BlobNotFound|ResourceNotFound') {
        Write-Warning ("Blob poll failed (exit {0}): {1}" -f $downloadRc, "$downloadOut")
        Invoke-AzRelogin
    }
    Write-Host ("... building ({0} min elapsed)" -f [int]($elapsed / 60))
    Show-AllLogDeltas
}

# --- Closing output -----------------------------------------------------------
Invoke-AzRelogin   # the build may have outlived the last refresh; ensure auth for the log pull
# Final delta first: run-build-task pushes the complete log just before the .done marker,
# so this picks up everything the last streaming cycle missed - including the failure.
Show-AllLogDeltas
# The 200-line tail is now a FALLBACK: if live streaming worked there is no point
# reprinting lines already above, but if it produced nothing (blob unreachable, old build
# VM image without the uploader) the tail is still the only visibility there is.
if ($streamPrinted["$statusPrefix/build.live.log"] -eq 0) {
    Write-Host "== Build log (tail) =="
    $logTmp = Join-Path ([IO.Path]::GetTempPath()) "bake-$buildId.log"
    Remove-Item $logTmp -Force -ErrorAction SilentlyContinue
    az storage blob download --account-name $stAccount --container-name $stContainer --name "$statusPrefix/build.log" --file $logTmp --auth-mode login --only-show-errors -o none 2>$null
    if (Test-Path $logTmp) { Get-Content $logTmp | ForEach-Object { Write-Host $_ } }
}
else { Write-Host ("== Build log streamed live above ({0} lines) ==" -f $streamPrinted["$statusPrefix/build.live.log"]) }

if ($null -eq $rc) { throw "Build did not finish within $maxMinutes minutes (timed out; VM will be torn down)." }
if ($rc -ne 0) { throw "Build FAILED (exit $rc). See log above." }

# --- Release notes / SBOM -----------------------------------------------------
try {
    $sbomName = "$statusPrefix/$image-$buildId.md"
    $sbomFile = "$image-$buildId.md"
    az storage blob download --account-name $stAccount --container-name $stContainer --name $sbomName --file $sbomFile --auth-mode login --only-show-errors -o none
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $sbomFile)) {
        Write-Host "== Release notes: $sbomFile =="
        if ($env:GITHUB_ENV) { "sbom_file=$sbomFile" | Add-Content -Path $env:GITHUB_ENV }
    } else { Write-Warning "Release notes unavailable: $sbomName" }
}
catch { Write-Warning "Release-notes fetch failed: $_" }
Write-Host "== Build succeeded: $image (build $buildId, commit $revision) =="
