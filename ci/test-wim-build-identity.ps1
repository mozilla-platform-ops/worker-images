$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$kickoff = Join-Path $PSScriptRoot 'kickoff-win-hw-wim-build.ps1'
$wrapper = Join-Path $root 'provisioners/windows/win-hw-wim/scripts/run-build-task.ps1'
foreach ($path in @($kickoff, $wrapper, (Join-Path $root 'provisioners/windows/win-hw-wim/bin/WinHwWim/New-WinHwWim.ps1'))) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { throw ($errors | Out-String) }
}
$tokens = $null; $errors = $null
$orchestrator = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'provisioners/windows/win-hw-wim/bin/WinHwWim/New-WinHwWim.ps1'), [ref]$tokens, [ref]$errors)
$notesAssignment = $orchestrator.Find({ param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$sbomRunBlob'
}, $true)
$StatusPrefix = '_status/win11-test/400/1'; $Image = 'win11-test'; $BuildId = 'same-label-400-1'
& ([scriptblock]::Create($notesAssignment.Extent.Text + '; $sbomRunBlob')) | ForEach-Object {
    if ($_ -ne '_status/win11-test/400/1/win11-test-same-label-400-1.md') { throw 'Notes publisher and downloader disagree.' }
}
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('wim-identity-' + [guid]::NewGuid())
$gitExe = (Get-Command git -CommandType Application | Select-Object -First 1).Source
$saved = @{}
foreach ($name in @('IMAGE', 'PIPELINE_SHA', 'BUILD_ID', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_ENV', 'ACTIONS_ID_TOKEN_REQUEST_URL', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN', 'Path')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
}
function Assert-Fails([scriptblock]$Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'Expected rejection.' }
}
function Arg($Arguments, $Name) { return $Arguments[[array]::IndexOf($Arguments, $Name) + 1] }
function Start-Sleep { }
function Start-Job { }
function Invoke-RestMethod { return @{ value = 'test-oidc-token' } }
function New-ScheduledTaskAction { param($Execute, $Argument) $global:wimIdentity_taskArguments = $Argument }
function Register-ScheduledTask { }
function Start-ScheduledTask { $global:wimIdentity_taskStarts++ }
function git {
    if ($args[0] -eq 'rev-parse') {
        Set-Variable LASTEXITCODE 0 -Scope 1
        return $global:wimIdentity_checkout
    }
    if ($global:wimIdentity_fetchFails -and $args -contains 'fetch') { Set-Variable LASTEXITCODE 1 -Scope 1; return }
    $output = & $gitExe @args
    $code = $LASTEXITCODE
    if ($global:wimIdentity_wrongHead -and $args -contains 'rev-parse') { $output = 'b' * 40 }
    Set-Variable LASTEXITCODE $code -Scope 1
    return $output
}
function az {
    Set-Variable LASTEXITCODE 0 -Scope 1
    if ($args[0] -eq 'identity') { return '11111111-1111-1111-1111-111111111111' }
    if ($args[0] -eq 'login' -or ($args[0] -eq 'account' -and $args[1] -eq 'set')) { return }
    if ($args[0] -eq 'account') { return '{"user":{"name":"test-client"},"tenantId":"test-tenant","id":"test-subscription"}' }
    if ($args[0] -eq 'vm') {
        $global:wimIdentity_remoteScript = Arg $args '--scripts'
        if ($global:wimIdentity_badSentinel) { return 'Error text quoting KICKOFF_OK without a success marker.' }
        return @('Initialized empty Git repository', 'KICKOFF_OK', 'HEAD is now at the selected commit')
    }
    if ($args[0] -ne 'storage' -or $args[1] -ne 'blob') { throw 'Unexpected Azure call.' }
    $name = Arg $args '--name'
    $file = Arg $args '--file'
    $global:wimIdentity_blobNames += $name
    if ($args[2] -eq 'download') {
        $text = if ($name.EndsWith('/build.done')) { '0' } else { 'test log or notes' }
        Set-Content -LiteralPath $file -Value $text
    } elseif ($args[2] -eq 'upload') {
        if ($name.EndsWith('/provenance.json') -and $global:wimIdentity_provenanceFails) { Set-Variable LASTEXITCODE 1 -Scope 1; return }
        $global:wimIdentity_uploads[$name] = Get-Content -LiteralPath $file -Raw
    } else { throw 'Unexpected shared-blob lookup or deletion.' }
}
function powershell.exe {
    $global:wimIdentity_childArguments = $args
    Set-Variable LASTEXITCODE $global:wimIdentity_childExit -Scope 1
    Write-Output 'test build output'
}
$pushed = $false
try {
    $origin = Join-Path $scratch 'origin'
    $builder = Join-Path $scratch 'builder'
    New-Item -ItemType Directory -Path "$origin/provisioners/windows/win-hw-wim/scripts" -Force | Out-Null
    & $gitExe -C $origin init -q -b main
    & $gitExe -C $origin config user.name Test
    & $gitExe -C $origin config user.email test@example.invalid
    'first' | Set-Content "$origin/marker"
    '' | Set-Content "$origin/provisioners/windows/win-hw-wim/scripts/run-build-task.ps1"
    & $gitExe -C $origin add .
    & $gitExe -C $origin commit -qm first
    $pin = (& $gitExe -C $origin rev-parse HEAD).Trim()
    'second' | Set-Content "$origin/marker"
    & $gitExe -C $origin commit -qam second
    Push-Location $scratch
    $pushed = $true
    $global:wimIdentity_checkout = $pin
    $global:wimIdentity_badSentinel = $false
    $env:IMAGE = 'win11-test'; $env:PIPELINE_SHA = $pin; $env:BUILD_ID = 'same-label'
    $env:GITHUB_ENV = Join-Path $scratch 'github-env'
    $env:ACTIONS_ID_TOKEN_REQUEST_URL = 'https://example.invalid/oidc?test=1'
    $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN = 'test-request-token'
    $paths = @(); $scripts = @()
    foreach ($identity in @(@('400', '1'), @('400', '2'), @('401', '1'))) {
        $env:GITHUB_RUN_ID = $identity[0]; $env:GITHUB_RUN_ATTEMPT = $identity[1]
        $global:wimIdentity_blobNames = @()
        & $kickoff
        $expected = "_status/win11-test/$($identity[0])/$($identity[1])/"
        if ($global:wimIdentity_blobNames | Where-Object { -not $_.StartsWith($expected) }) { throw 'Cross-run blob access.' }
        $paths += ,$global:wimIdentity_blobNames
        $scripts += $global:wimIdentity_remoteScript
    }
    foreach ($name in $paths[0]) { if ($paths[1] -contains $name -or $paths[2] -contains $name) { throw 'Run artifacts overlap.' } }
    $env:PIPELINE_SHA = ''
    & $kickoff
    if ($global:wimIdentity_remoteScript -notmatch [regex]::Escape("fetch --depth=1 origin '$pin'")) { throw 'Legacy workflow did not use its checked-out commit.' }
    foreach ($bad in @('main', ('a' * 8), ('a' * 40))) {
        $env:PIPELINE_SHA = $bad
        Assert-Fails { & $kickoff }
    }
    $env:PIPELINE_SHA = $pin; $global:wimIdentity_badSentinel = $true
    Assert-Fails { & $kickoff }
    $global:wimIdentity_badSentinel = $false
    $env:BUILD_ID = '-bad-label'
    Assert-Fails { & $kickoff }
    $env:BUILD_ID = 'same-label'; $env:GITHUB_RUN_ATTEMPT = '../2'
    Assert-Fails { & $kickoff }

    $remote = $scripts[0].Replace('C:\worker-images', $builder.Replace("'", "''")).Replace(
        'https://github.com/mozilla-platform-ops/worker-images.git', $origin.Replace("'", "''"))
    $global:wimIdentity_taskStarts = 0
    & ([scriptblock]::Create($remote))
    if ($global:wimIdentity_taskStarts -ne 1 -or (Get-Content "$builder/marker") -ne 'first') { throw 'Builder followed the moving branch.' }
    if ($global:wimIdentity_taskArguments -notmatch [regex]::Escape("-PipelineRevision $pin") -or $global:wimIdentity_taskArguments -notmatch '-StatusPrefix _status/win11-test/400/1' -or $global:wimIdentity_taskArguments -notmatch '-BuildId same-label-400-1') { throw 'Task lost its build identity.' }
    foreach ($failure in @('fetch', 'head')) {
        $global:wimIdentity_fetchFails = $failure -eq 'fetch'; $global:wimIdentity_wrongHead = $failure -eq 'head'
        $global:wimIdentity_taskStarts = 0
        Assert-Fails { & ([scriptblock]::Create($remote)) }
        if ($global:wimIdentity_taskStarts) { throw 'Started task after a failed checkout.' }
    }
    $global:wimIdentity_fetchFails = $false; $global:wimIdentity_wrongHead = $false
    $env:Path = $saved.Path

    $base = Join-Path $scratch 'status'
    $testWrapper = Join-Path $builder 'provisioners/windows/win-hw-wim/scripts/run-build-task.ps1'
    (Get-Content $wrapper -Raw).Replace("'C:\win-hw-wim-build'", "'$($base.Replace("'", "''"))'") | Set-Content $testWrapper
    Assert-Fails { & $testWrapper -Image win11-test -BuildId test -PipelineRevision $pin -StatusPrefix '_status/other-image/400/1' }
    foreach ($case in @(
        @{ child = 0; provenance = $false; mismatch = $false; expected = 0 },
        @{ child = $null; provenance = $false; mismatch = $false; expected = 1 },
        @{ child = 7; provenance = $false; mismatch = $false; expected = 7 },
        @{ child = 0; provenance = $true; mismatch = $false; expected = 1 },
        @{ child = 0; provenance = $false; mismatch = $true; expected = 1 }
    )) {
        $global:wimIdentity_childExit = $case.child; $global:wimIdentity_provenanceFails = $case.provenance
        $global:wimIdentity_wrongHead = $case.mismatch; $global:wimIdentity_uploads = @{}; $global:wimIdentity_blobNames = @(); $global:wimIdentity_childArguments = @()
        & $testWrapper -Image win11-test -BuildId test-400-1 -PipelineRevision $pin -StatusPrefix '_status/win11-test/400/1'
        if (-not $global:wimIdentity_uploads.ContainsKey('_status/win11-test/400/1/build.done')) { throw 'Completion marker missing.' }
        if (-not $case.mismatch -and (Arg $global:wimIdentity_childArguments '-StatusPrefix') -ne '_status/win11-test/400/1') { throw 'Child lost status prefix.' }
        if ([int]$global:wimIdentity_uploads['_status/win11-test/400/1/build.done'] -ne $case.expected) { throw 'Incorrect completion result.' }
        if ($global:wimIdentity_blobNames[-1] -ne '_status/win11-test/400/1/build.done') { throw 'Completion was not uploaded last.' }
        if ($case.mismatch -and $global:wimIdentity_childArguments.Count) { throw 'Build started from the wrong revision.' }
        if (-not $case.provenance) {
            $receipt = $global:wimIdentity_uploads['_status/win11-test/400/1/provenance.json'] | ConvertFrom-Json
            if ($receipt.pipelineRevision -ne $pin -or $receipt.buildId -ne 'test-400-1') { throw 'Incorrect provenance.' }
        }
    }
}
finally {
    if ($pushed) { Pop-Location }
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    Get-Variable -Name 'wimIdentity_*' -Scope Global | Remove-Variable -Scope Global
}
$global:LASTEXITCODE = 0
Write-Host 'WIM immutable checkout and run isolation checks passed.'
