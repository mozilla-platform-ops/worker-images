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
$vm      = if ($env:VM_NAME) { $env:VM_NAME } else { 'win-hw-wim-builder' }
$rg      = if ($env:RESOURCE_GROUP) { $env:RESOURCE_GROUP } else { 'rg-central-us-nuc-wim' }

# Inputs flow into a remote script — allow only safe characters.
foreach ($v in @($image, $ref)) { if ($v -notmatch '^[A-Za-z0-9._/-]+$') { throw "Illegal input: '$v'" } }
if ($buildId -and $buildId -notmatch '^[A-Za-z0-9._-]+$') { throw "Illegal BUILD_ID: '$buildId'" }

# NOTE: no quotes around the values below. This becomes a scheduled-task -Argument
# string parsed by powershell.exe -File via CommandLineToArgvW, which strips double
# quotes but keeps single quotes LITERAL (they'd end up in $Image). Inputs are already
# validated to [A-Za-z0-9._/-]+ (no spaces), so they need no quoting.
$buildArg = if ($buildId) { "-BuildId $buildId" } else { '' }

# The build VM has only a USER-assigned managed identity, so New-WinHwWim must log in
# with `az login --identity --username <clientId>`. Resolve that client id here (this
# runner is az-authenticated via OIDC) and pass it through to the build.
$idName = if ($env:BUILDER_IDENTITY_NAME) { $env:BUILDER_IDENTITY_NAME } else { 'id-central-us-wim-builder' }
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

Write-Host "== Starting build '$image' (ref '$ref') on $vm =="
$out = az vm run-command invoke -g $rg -n $vm --command-id RunPowerShellScript --scripts "$start" --query "join('`n', value[].message)" -o tsv
Write-Host $out
# az vm run-command returns 0 even if the inner script threw — assert the sentinel so a
# failed checkout/register fails fast instead of polling a build that never started.
if ("$out" -notmatch 'KICKOFF_OK') { throw "Failed to start the build on $vm (no KICKOFF_OK):`n$out" }

# --- Poll the completion marker -----------------------------------------------
# The `az vm run-command invoke` action API serializes per VM and, under the heavy
# nested-virt bake load, intermittently returns "Conflict: execution in progress" (or an
# empty result). Previously a failed read silently cost a whole 60s cycle and left NO
# trace, so a build that had already written build.done could go undetected and the job
# would hang for hours. Retry the read a few times per cycle and log the raw status each
# cycle so a stuck poll is visible. (Also: do NOT run other az vm run-commands against
# this VM while the job runs — a concurrent invoke makes THIS poll Conflict.)
$intervalSec = 60
$maxMinutes  = 300   # hard cap (~5h) so a hung build can't run the job forever
$poll = "if (Test-Path 'C:\win-hw-wim-build\build.done') { 'DONE:' + (Get-Content 'C:\win-hw-wim-build\build.done' -Raw).Trim() } else { 'RUNNING' }"
$rc = $null
for ($elapsed = 0; $elapsed -lt ($maxMinutes * 60); $elapsed += $intervalSec) {
    Start-Sleep -Seconds $intervalSec
    $status = $null
    for ($try = 1; $try -le 4 -and [string]::IsNullOrWhiteSpace($status); $try++) {
        if ($try -gt 1) { Start-Sleep -Seconds 10 }
        $status = (az vm run-command invoke -g $rg -n $vm --command-id RunPowerShellScript --scripts "$poll" --query "value[0].message" -o tsv 2>$null)
    }
    if ($status -match 'DONE:(-?\d+)') { $rc = [int]$Matches[1]; break }
    Write-Host ("... building ({0} min elapsed; status='{1}')" -f [int]($elapsed / 60), (($status -replace '\s+', ' ').Trim()))
}

# --- Fetch the log tail for visibility ----------------------------------------
Write-Host "== Build log (tail) =="
$tail = (az vm run-command invoke -g $rg -n $vm --command-id RunPowerShellScript `
        --scripts "if (Test-Path 'C:\win-hw-wim-build\build.log') { Get-Content 'C:\win-hw-wim-build\build.log' -Tail 120 -ErrorAction SilentlyContinue }" `
        --query "value[0].message" -o tsv 2>$null)
Write-Host $tail

if ($null -eq $rc) { throw "Build did not finish within $maxMinutes minutes (timed out; VM will be torn down)." }
if ($rc -ne 0) { throw "Build FAILED (exit $rc). See log above." }
Write-Host "== Build succeeded: $image -> captured/$image/ =="
