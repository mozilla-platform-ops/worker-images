<#
.SYNOPSIS
  Run a Windows HW WIM build on the ephemeral Azure build VM and WAIT for it. Runs on
  the GitHub Actions runner (pwsh + az, already authenticated by azure/login).

.DESCRIPTION
  The build needs nested Hyper-V (can't run on the GH-hosted runner) and exceeds the
  ~90-min az vm run-command limit, so this:
    1. has the VM check out worker-images at PIPELINE_REF and launch the build as a
       detached scheduled task (provisioners/.../scripts/run-build-task.ps1, which
       writes C:\win-hw-wim-build\build.done with the exit code when finished), then
    2. polls that marker until the build finishes, streaming the tail of the log,
    3. exits with the build's result so the workflow job passes/fails accordingly.

  The workflow creates the VM before this step and destroys it after (if: always()).

  Env (set by the workflow):
    IMAGE, PIPELINE_REF, BUILD_ID (optional), VM_NAME, RESOURCE_GROUP
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$image   = $env:IMAGE;        if (-not $image) { throw 'IMAGE not set' }
$ref     = $env:PIPELINE_REF; if (-not $ref)   { throw 'PIPELINE_REF not set' }
$buildId = $env:BUILD_ID
$stages  = $env:STAGES        # blank = default prep,build,publish bake; e.g. 'iso' for the ISO stage
$vm      = if ($env:VM_NAME) { $env:VM_NAME } else { 'win-hw-wim-builder' }
$rg      = if ($env:RESOURCE_GROUP) { $env:RESOURCE_GROUP } else { 'rg-central-us-hardware-imaging' }

# Inputs flow into a remote script — allow only safe characters.
foreach ($v in @($image, $ref)) { if ($v -notmatch '^[A-Za-z0-9._/-]+$') { throw "Illegal input: '$v'" } }
if ($buildId -and $buildId -notmatch '^[A-Za-z0-9._-]+$') { throw "Illegal BUILD_ID: '$buildId'" }
if ($stages -and $stages -notmatch '^[A-Za-z,]+$') { throw "Illegal STAGES: '$stages'" }

# NOTE: no quotes around the values below. This becomes a scheduled-task -Argument
# string parsed by powershell.exe -File via CommandLineToArgvW, which strips double
# quotes but keeps single quotes LITERAL (they'd end up in $Image). Inputs are already
# validated to [A-Za-z0-9._/-]+ (no spaces), so they need no quoting.
$buildArg = if ($buildId) { "-BuildId $buildId" } else { '' }
if ($stages) { $buildArg = "$buildArg -Stages $stages".Trim() }

# The build VM has only a USER-assigned managed identity, so New-WinHwWim must log in
# with `az login --identity --username <clientId>`. Resolve that client id here (this
# runner is az-authenticated via OIDC) and pass it through to the build.
$idName = if ($env:BUILDER_IDENTITY_NAME) { $env:BUILDER_IDENTITY_NAME } else { 'id-central-us-hardware-imaging-builder' }
$idClientId = (az identity show -g $rg -n $idName --query clientId -o tsv 2>$null)
if ($idClientId) { $buildArg = "$buildArg -IdentityClientId $idClientId".Trim() }
else { Write-Warning "Could not resolve client id for identity '$idName' in '$rg'; build may fail to az login." }

# Forward a GitHub token (build-scoped) so puppet's tooltool download in the bake can
# authenticate. Set it as a MACHINE env var so the SYSTEM scheduled task inherits it and
# New-WinHwWim's -GithubPat default ($env:GITHUB_TOKEN) picks it up. Empty is fine —
# tooltool.py is public and downloads without a token.
$ghToken = ($env:GITHUB_TOKEN, $env:PACKER_GITHUB_API_TOKEN, '' | Where-Object { $_ } | Select-Object -First 1)
$ghTokenLine = if ($ghToken) {
    "[Environment]::SetEnvironmentVariable('GITHUB_TOKEN', '$ghToken', 'Machine'); `$env:GITHUB_TOKEN = '$ghToken'"
}
else { "# no GitHub token provided; tooltool downloads unauthenticated (public)" }

# --- Storage-backed completion signal -----------------------------------------
# The bake (run-build-task.ps1) uploads a _status/<image>.done marker (+ .log) to blob;
# we poll THAT with the runner's own az instead of polling build.done over
# `az vm run-command`, which wedges under the bake's nested-virt load and left finished
# builds undetected (job hung ~2h). Best-effort delete any stale marker from a prior run -
# but do NOT rely on it: the runner SP may lack blob-delete, so the delete can silently
# no-op (it did - a yesterday marker survived and made a run FALSE-pass in ~1 min). The
# real guard is the freshness gate below: only a marker written AFTER this kickoff counts.
$stAccount   = 'hardwareimaging'
$stContainer = 'captured'
foreach ($n in @("_status/$image.done", "_status/$image.log", "_status/$image.live.log")) {
    az storage blob delete --account-name $stAccount --container-name $stContainer --name $n --auth-mode login --only-show-errors 2>$null
}

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
$ghTokenLine
# Refresh PATH from the machine env — tools installed by choco after the guest agent
# started (no reboot since) aren't on this run-command's inherited PATH otherwise.
`$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
`$repo = 'C:\worker-images'
if (Test-Path `$repo) {
    git -C `$repo fetch --all --prune
    git -C `$repo checkout '$ref'
    git -C `$repo reset --hard 'origin/$ref'
} else {
    git clone --branch '$ref' https://github.com/mozilla-platform-ops/worker-images.git `$repo
}
if (-not (Test-Path (Join-Path `$repo 'provisioners\windows\win-hw-wim\scripts\run-build-task.ps1'))) { throw 'repo checkout missing run-build-task.ps1' }
`$task = Join-Path `$repo 'provisioners\windows\win-hw-wim\scripts\run-build-task.ps1'
`$arg  = "-NoProfile -ExecutionPolicy Bypass -File ""`$task"" -Image $image $buildArg"
`$act  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument `$arg
Register-ScheduledTask -TaskName 'win-hw-wim-build' -Action `$act -RunLevel Highest -User 'SYSTEM' -Force | Out-Null
Start-ScheduledTask -TaskName 'win-hw-wim-build'
Write-Output 'KICKOFF_OK'
"@

# Freshness gate: any .done marker older than this instant is stale (a prior run's) and
# must be ignored. Captured just before we start the build, so only THIS build's marker
# (written ~1h40m later) counts as completion.
$kickoffUtc = (Get-Date).ToUniversalTime()
Write-Host "== Starting build '$image' (ref '$ref') on $vm (kickoff $($kickoffUtc.ToString('o'))) =="
$out = az vm run-command invoke -g $rg -n $vm --command-id RunPowerShellScript --scripts "$start" --query "join('`n', value[].message)" -o tsv
Write-Host $out
# az vm run-command returns 0 even if the inner script threw — assert the sentinel so a
# failed checkout/register fails fast instead of polling a build that never started.
if ("$out" -notmatch 'KICKOFF_OK') { throw "Failed to start the build on $vm (no KICKOFF_OK):`n$out" }

# --- Poll the completion marker (from blob, NOT run-command) -------------------
# run-build-task.ps1 uploads _status/<image>.done (content = exit code) when the build
# finishes. We poll that blob with the runner's own az - completely independent of the
# VM's run-command extension, which wedged under bake load and never surfaced build.done.
$intervalSec = 60
$maxMinutes  = 240   # hard cap; a real bake is ~90-150 min (windows_update=true images
                     # sit at the top of that range, and their two windows-restart
                     # provisioners may each burn up to 60m). The poll stays
                     # authenticated (OIDC re-login below), so hitting this means a
                     # genuinely stuck build - not a monitoring blind spot as before.
$reloginEverySec = 1200   # re-auth every ~20 min so the ~1h azure/login token never lapses
$rc = $null
$doneName = "_status/$image.done"
$doneTmp  = Join-Path ([IO.Path]::GetTempPath()) "bake-$image.done"

# --- Live build-log streaming -------------------------------------------------
# run-build-task.ps1 pushes the WHOLE build.log to _status/<image>.live.log every minute.
# Download it each poll and print only the lines we haven't printed yet, so the GH log
# follows the bake in real time instead of showing a 200-line tail two hours later (and
# nothing at all when a hang runs the job into its timeout and the VM is destroyed).
$liveName    = "_status/$image.live.log"
$liveTmp     = Join-Path ([IO.Path]::GetTempPath()) "bake-$image.live.log"
$livePrinted = 0
function Show-LiveLogDelta {
    Remove-Item $liveTmp -Force -ErrorAction SilentlyContinue
    # Freshness-gate exactly like the .done marker: a leftover live.log from a previous
    # run would otherwise replay a stale build into this job's output.
    $mod = az storage blob show --account-name $stAccount --container-name $stContainer --name $liveName --auth-mode login --query "properties.lastModified" -o tsv 2>$null
    if (($LASTEXITCODE -ne 0) -or (-not $mod)) { return }
    if (([datetimeoffset]("$mod".Trim())).UtcDateTime -le $kickoffUtc) { return }
    az storage blob download --account-name $stAccount --container-name $stContainer --name $liveName --file $liveTmp --auth-mode login --only-show-errors 2>$null
    if (-not (Test-Path $liveTmp)) { return }
    $lines = @(Get-Content $liveTmp -ErrorAction SilentlyContinue)
    if ($lines.Count -le $script:livePrinted) { return }
    $lines[$script:livePrinted..($lines.Count - 1)] | ForEach-Object { Write-Host $_ }
    $script:livePrinted = $lines.Count
}

# --- SolarWinds (papertrail) tail ---------------------------------------------
# The bake guest ships to SolarWinds as $swoHost from the moment puppet's logging profile
# starts nxlog (win_nxlog::service ensure => running). VERIFIED on the 20260811-164648
# bake: it covers the final boot + sysprep window. Scoped by default to OUR OWN script
# output (nxlog + the bootstrap/puppet/ronin sources) - the Windows event-log noise
# (Microsoft-Windows-*, Service_Control_Manager, User32 ...) is deliberately dropped, but
# the count of dropped lines IS reported so nothing disappears silently. Widen with
# SWO_PROGRAM_FILTER if you ever need the OS chatter.
# No token => the tail is skipped with a notice; it is a diagnostic, never a build gate.
$swoToken   = $env:SOLARWINDS_API_TOKEN
$swoHostTag = if ($env:SWO_BAKE_HOST) { $env:SWO_BAKE_HOST } else { 'nuc-bake' }
$swoApi     = if ($env:SWO_API_BASE) { $env:SWO_API_BASE } else { 'https://api.na-01.cloud.solarwinds.com/v1/logs' }
$swoFilter  = if ($env:SWO_PROGRAM_FILTER) { $env:SWO_PROGRAM_FILTER } else { '^(nxlog|BootStrap|bootstrap|puppet|ronin|maintainsystem|Ronin)' }
# Message-level drop for nxlog's own guaranteed-useless chatter: it tails the
# generic-worker logs, which NEVER exist on a bake VM, so it re-warns about each missing
# file every few seconds (24 of the 29 nxlog lines on the 20260811-164648 bake). Set
# SWO_MESSAGE_DROP='' to keep them.
$swoMsgDrop = if ($null -ne $env:SWO_MESSAGE_DROP) { $env:SWO_MESSAGE_DROP } else { 'input file does not exist|has no input files to read' }
$swoSince   = $kickoffUtc
$swoSeen    = [System.Collections.Generic.HashSet[string]]::new()
$swoDropped = 0
$swoWarned  = $false
if (-not $swoToken) {
    Write-Host "  (SOLARWINDS_API_TOKEN not set - skipping the $swoHostTag log tail; add the repo secret + workflow env to enable it)"
}
function Show-SolarWindsDelta {
    if (-not $swoToken) { return }
    $now = (Get-Date).ToUniversalTime()
    try {
        $uri = ('{0}?filter={1}&startTime={2}&endTime={3}&pageSize=500' -f $swoApi, [uri]::EscapeDataString($swoHostTag),
            $script:swoSince.ToString('yyyy-MM-ddTHH:mm:ssZ'), $now.ToString('yyyy-MM-ddTHH:mm:ssZ'))
        $resp = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $swoToken" } -TimeoutSec 30
    }
    catch {
        # One warning per build, not one per minute: the tail is best-effort.
        if (-not $script:swoWarned) { Write-Warning "SolarWinds log tail unavailable (continuing without it): $_"; $script:swoWarned = $true }
        return
    }
    $entries = @($resp.logs)
    if ($entries.Count -ge 500) { Write-Host "  [swo] page limit hit - some entries in this interval were not fetched" }
    foreach ($e in $entries) {
        if (-not $script:swoSeen.Add([string]$e.id)) { continue }
        if ("$($e.program)" -notmatch $swoFilter) { $script:swoDropped++; continue }
        if ($swoMsgDrop -and ("$($e.message)" -match $swoMsgDrop)) { $script:swoDropped++; continue }
        Write-Host ("  [swo] {0} {1}: {2}" -f $e.time, $e.program, $e.message)
    }
    $script:swoSince = $now
}
for ($elapsed = 0; $elapsed -lt ($maxMinutes * 60); $elapsed += $intervalSec) {
    Start-Sleep -Seconds $intervalSec
    # Refresh the Azure token before it can expire (azure/login's lasts ~1h; bake ~2h).
    if (($elapsed % $reloginEverySec) -eq 0) { Invoke-AzRelogin }
    # Check the marker's lastModified FIRST (not just existence) - a leftover marker from a
    # prior run would otherwise false-pass instantly. Capture stderr instead of blackholing
    # it (2>$null hid the expired-token failure for 4h): BlobNotFound is the normal
    # not-done-yet case, but anything else (auth/network) must be SURFACED.
    $modOut = az storage blob show --account-name $stAccount --container-name $stContainer --name $doneName --auth-mode login --query "properties.lastModified" -o tsv 2>&1
    $showRc = $LASTEXITCODE
    if (($showRc -eq 0) -and $modOut) {
        $modUtc = ([datetimeoffset]("$modOut".Trim())).UtcDateTime
        if ($modUtc -gt $kickoffUtc) {
            # Fresh marker from THIS build - read the exit code it carries.
            Remove-Item $doneTmp -Force -ErrorAction SilentlyContinue
            az storage blob download --account-name $stAccount --container-name $stContainer --name $doneName --file $doneTmp --auth-mode login --only-show-errors 2>$null
            if (Test-Path $doneTmp) { $rc = [int]((Get-Content $doneTmp -Raw).Trim()); break }
        } else {
            Write-Host "  (ignoring stale marker from $modUtc; predates kickoff $kickoffUtc)"
        }
    } elseif (($showRc -ne 0) -and ("$modOut" -notmatch '(?i)not\s*found|does not exist|BlobNotFound|ResourceNotFound')) {
        Write-Warning ("blob poll error (exit {0}): {1}" -f $showRc, (("$modOut" -replace '\s+', ' ').Trim()))
        Invoke-AzRelogin   # most likely the token lapsed between refreshes; re-auth now
    }
    Write-Host ("... building ({0} min elapsed)" -f [int]($elapsed / 60))
    Show-LiveLogDelta
    Show-SolarWindsDelta
}

# --- Closing output -----------------------------------------------------------
Invoke-AzRelogin   # the build may have outlived the last refresh; ensure auth for the log pull
# Final delta first: run-build-task pushes the complete log just before the .done marker,
# so this picks up everything the last streaming cycle missed - including the failure.
Show-LiveLogDelta
Show-SolarWindsDelta
if ($swoDropped) { Write-Host "  [swo] $swoDropped OS event-log lines filtered out (set SWO_PROGRAM_FILTER to widen)" }
# The 200-line tail is now a FALLBACK: if live streaming worked there is no point
# reprinting lines already above, but if it produced nothing (blob unreachable, old build
# VM image without the uploader) the tail is still the only visibility there is.
if ($livePrinted -eq 0) {
    Write-Host "== Build log (tail) =="
    $logTmp = Join-Path ([IO.Path]::GetTempPath()) "bake-$image.log"
    Remove-Item $logTmp -Force -ErrorAction SilentlyContinue
    az storage blob download --account-name $stAccount --container-name $stContainer --name "_status/$image.log" --file $logTmp --auth-mode login --only-show-errors 2>$null
    if (Test-Path $logTmp) { Get-Content $logTmp | ForEach-Object { Write-Host $_ } }
}
else { Write-Host "== Build log streamed live above ($livePrinted lines) ==" }

if ($null -eq $rc) { throw "Build did not finish within $maxMinutes minutes (timed out; VM will be torn down)." }
if ($rc -ne 0) { throw "Build FAILED (exit $rc). See log above." }

# --- Release notes / SBOM -----------------------------------------------------
# The bake generates the same <config>-<version>.md the Azure gallery images do (see
# win-hw-wim.pkr.hcl) and publishes it to _status/sbom/. Pull it into the workspace and
# hand the filename to the workflow via GITHUB_ENV - exactly how sig-*.yml passes
# sharedimageversion - so the upload-artifact step can feed
# .github/workflows/upload-release-notes.yml, which commits it to sboms/ on main.
# Listed by PREFIX rather than an exact name because the build id is generated by
# New-WinHwWim, so the runner never knows it up front.
# Best-effort: a good WIM must not fail the job over its release notes.
try {
    $sbomPrefix = "_status/sbom/$image-"
    $sbomJson = az storage blob list --account-name $stAccount --container-name $stContainer --prefix $sbomPrefix --auth-mode login --query "[].{name:name, mod:properties.lastModified}" -o json 2>$null
    $sbomList = @()
    if ($sbomJson) { $sbomList = @($sbomJson | ConvertFrom-Json) }
    # Freshness-gated like every other marker here: only THIS build's notes count.
    $sbomPick = $sbomList |
        Where-Object { ([datetimeoffset]$_.mod).UtcDateTime -gt $kickoffUtc } |
        Sort-Object { ([datetimeoffset]$_.mod).UtcDateTime } -Descending |
        Select-Object -First 1
    if ($sbomPick) {
        $sbomFile = Split-Path $sbomPick.name -Leaf
        az storage blob download --account-name $stAccount --container-name $stContainer --name $sbomPick.name --file $sbomFile --auth-mode login --only-show-errors 2>$null
        if (Test-Path $sbomFile) {
            Write-Host "== Release notes: $sbomFile =="
            if ($env:GITHUB_ENV) { "sbom_file=$sbomFile" | Add-Content -Path $env:GITHUB_ENV }
        }
        else { Write-Warning "release notes blob '$($sbomPick.name)' could not be downloaded; nothing to commit to sboms/" }
    }
    else { Write-Warning "no release notes found under $sbomPrefix newer than this kickoff; nothing to commit to sboms/" }
}
catch {
    Write-Warning "release-notes fetch failed (build itself succeeded): $_"
}
Write-Host "== Build succeeded: $image -> captured/$image/ =="
