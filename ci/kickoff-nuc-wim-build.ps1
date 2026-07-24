<#
.SYNOPSIS
  Kick off a NUC install.wim build on the Azure nested-virt build host. Runs on the
  GitHub Actions runner (pwsh + az, already authenticated by azure/login).

.DESCRIPTION
  The WIM build needs nested Hyper-V, which GitHub-hosted runners can't do, so this
  drives the pre-provisioned Azure build VM (see
  provisioners/windows/nuc-wim/New-NucWimBuildVm.ps1):

    1. ensure the builder VM is running,
    2. via `az vm run-command`, have it clone/checkout worker-images at the pipeline
       branch and launch New-NucWim.ps1 as a SCHEDULED TASK (so the long build
       survives past the run-command window), then return.

  It's a fire-and-forth kickoff: progress is on the VM
  (C:\nuc-wim-build\logs) and the result lands in the captured/ blob container.

  Inputs come from env (set by the workflow):
    IMAGE          config/<image>.yaml to build (e.g. win11-24h2-hw)
    PIPELINE_REF   worker-images branch holding provisioners/windows/nuc-wim
    BUILD_ID       optional build id (default: timestamp on the VM)
    VM_NAME        default nuc-wim-builder
    RESOURCE_GROUP default rg-central-us-nuc-wim
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$image = $env:IMAGE;        if (-not $image) { throw 'IMAGE not set' }
$ref   = $env:PIPELINE_REF; if (-not $ref)   { throw 'PIPELINE_REF not set' }
$buildId = $env:BUILD_ID
$vm    = if ($env:VM_NAME) { $env:VM_NAME } else { 'nuc-wim-builder' }
$rg    = if ($env:RESOURCE_GROUP) { $env:RESOURCE_GROUP } else { 'rg-central-us-nuc-wim' }

# Inputs flow into a remote script — allow only safe identifier characters.
foreach ($v in @($image, $ref)) {
    if ($v -notmatch '^[A-Za-z0-9._/-]+$') { throw "Illegal characters in input: '$v'" }
}
if ($buildId -and $buildId -notmatch '^[A-Za-z0-9._-]+$') { throw "Illegal BUILD_ID: '$buildId'" }

Write-Host "== Ensuring $vm is running =="
$state = (az vm get-instance-view -g $rg -n $vm --query "instanceView.statuses[?starts_with(code,'PowerState/')].code" -o tsv)
if ($state -ne 'PowerState/running') {
    Write-Host "   current: $state -> starting"
    az vm start -g $rg -n $vm --only-show-errors | Out-Null
}

$buildArg = if ($buildId) { "-BuildId $buildId" } else { '' }

# Script executed ON the builder VM.
$remote = @"
`$ErrorActionPreference = 'Stop'
`$repo = 'C:\worker-images'
`$log  = 'C:\nuc-wim-build\logs'
New-Item -ItemType Directory -Path `$log -Force | Out-Null

# Build host authenticates with its system-assigned managed identity.
az login --identity --only-show-errors | Out-Null

if (Test-Path `$repo) {
    git -C `$repo fetch --all --prune
    git -C `$repo checkout '$ref'
    git -C `$repo reset --hard 'origin/$ref'
} else {
    git clone --branch '$ref' https://github.com/mozilla-platform-ops/worker-images.git `$repo
}

`$nuc = Join-Path `$repo 'provisioners\windows\nuc-wim'
`$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
`$logf = Join-Path `$log "$image-`$stamp.log"

# Run the build detached as a scheduled task so it outlives this run-command.
`$cmd = "& '`$nuc\bin\NucWim\New-NucWim.ps1' -Image '$image' $buildArg *>&1 | Tee-Object -FilePath '`$logf'"
`$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -Command `"`$cmd`""
Register-ScheduledTask -TaskName 'nuc-wim-build' -Action `$action -RunLevel Highest -User 'SYSTEM' -Force | Out-Null
Start-ScheduledTask -TaskName 'nuc-wim-build'
Write-Output "kicked off build of $image ($ref) on `$env:COMPUTERNAME; log: `$logf"
"@

Write-Host "== Kicking off build of '$image' from ref '$ref' on $vm =="
$out = az vm run-command invoke -g $rg -n $vm --command-id RunPowerShellScript --scripts "$remote" `
    --query "value[0].message" -o tsv
Write-Host $out
Write-Host "== Kickoff complete. Build runs on $vm; output -> captured/$image/ =="
