# Run from the repository root. Only Packer and module installation are mocked.
$ErrorActionPreference = 'Stop'
Import-Module powershell-yaml
. ./bin/WorkerImages/Public/New-AzSharedWorkerImage.ps1
function Set-PSRepository { }
function Install-Module { }

$check = @{ calls = @(); directory = ''; fail = '' }
function packer {
    $check.calls += $args[0]
    $check.directory = $env:PKR_VAR_upload_directory
    if (-not (Test-Path "$($check.directory)/Bootstrap.zip") -or
        -not (Test-Path "$($check.directory)/tests.zip")) {
        throw 'Packer started without both upload archives.'
    }
    if ($args[0] -eq 'build') {
        if (($args -contains '-force') -ne ($env:PKR_VAR_config -like '*alpha*')) {
            throw 'The image overwrite policy changed.'
        }
        # Extract at the same relative paths used by the guest provisioner.
        Expand-Archive "$($check.directory)/Bootstrap.zip" "$($check.directory)/Modules"
        Expand-Archive "$($check.directory)/tests.zip" "$($check.directory)/Tests"
        foreach ($pair in @(
            @('scripts/windows/CustomFunctions/Bootstrap', "$($check.directory)/Modules/Bootstrap"),
            @('tests/win', "$($check.directory)/Tests")
        )) {
            $source = (Resolve-Path $pair[0]).Path
            $files = @(Get-ChildItem $source -File -Recurse -Force)
            if ($files.Count -ne @(Get-ChildItem $pair[1] -File -Recurse -Force).Count) {
                throw "Archive file count changed: $source"
            }
            foreach ($file in $files) {
                $relative = [IO.Path]::GetRelativePath($source, $file.FullName)
                $copy = Join-Path $pair[1] $relative
                if ((Get-FileHash $file.FullName).Hash -ne (Get-FileHash $copy).Hash) {
                    throw "Archive changed a file: $relative"
                }
            }
        }
    }
    $global:LASTEXITCODE = if ($args[0] -eq $check.fail) { 7 } else { 0 }
}

foreach ($case in @(
    @('win11-64-24h2-alpha', ''),
    @('trusted-win2025-64-24h2', ''),
    @('win11-64-24h2-alpha', 'init'),
    @('win11-64-24h2-alpha', 'build')
)) {
    $check.calls = @()
    $check.fail = $case[1]
    $env:PKR_VAR_upload_directory = 'previous-value'
    $failure = $null
    try {
        New-AzSharedWorkerImage -Key $case[0] 6>$null
    } catch { $failure = $_ }
    if ($case[1]) {
        if (-not $failure -or $failure.ToString() -notlike "packer $($case[1]) failed with exit code 7*") {
            throw "Expected the native Packer failure, got: $failure"
        }
    } elseif ($failure) { throw $failure }
    $expectedCalls = if ($case[1] -eq 'init') { 'init' } else { 'init,build' }
    if (($check.calls -join ',') -ne $expectedCalls) { throw 'Wrong Packer call sequence.' }
    if (Test-Path $check.directory) { throw 'Upload archives were not removed.' }
    if ($env:PKR_VAR_upload_directory -ne 'previous-value') { throw 'Upload environment was not restored.' }
}
# GitHub Actions uses LASTEXITCODE as the step result; clear the mocked failure.
$global:LASTEXITCODE = 0
Write-Host 'Archive contents, overwrite policy, Packer failures, and cleanup passed.'
