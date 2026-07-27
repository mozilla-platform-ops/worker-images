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

$buildArg = if ($buildId) { "-BuildId '$buildId'" } else { '' }

# --- Start the build (checkout repo + register/start the scheduled task) -------
$start = @"
`$ErrorActionPreference = 'Stop'
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
`$arg  = "-NoProfile -ExecutionPolicy Bypass -File ""`$task"" -Image '$image' $buildArg"
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
$intervalSec = 60
$maxMinutes  = 300   # hard cap (~5h) so a hung build can't run the job forever
$poll = "if (Test-Path 'C:\win-hw-wim-build\build.done') { 'DONE:' + (Get-Content 'C:\win-hw-wim-build\build.done' -Raw).Trim() } else { 'RUNNING' }"
$rc = $null
for ($elapsed = 0; $elapsed -lt ($maxMinutes * 60); $elapsed += $intervalSec) {
    Start-Sleep -Seconds $intervalSec
    $status = (az vm run-command invoke -g $rg -n $vm --command-id RunPowerShellScript --scripts "$poll" --query "value[0].message" -o tsv 2>$null)
    if ($status -match 'DONE:(-?\d+)') { $rc = [int]$Matches[1]; break }
    Write-Host ("... building ({0} min elapsed)" -f [int]($elapsed / 60))
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
