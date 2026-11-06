$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$wimRoot = Join-Path $root 'provisioners/windows/win-hw-wim'
function Read-Ast($Path) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    return $ast
}
foreach ($path in @(
    (Join-Path $root 'ci/kickoff-win-hw-wim-build.ps1'),
    (Join-Path $wimRoot 'bin/WinHwWim/New-WinHwWim.ps1'),
    (Join-Path $wimRoot 'scripts/bake-bootstrap.ps1'),
    (Join-Path $wimRoot 'variables.pkr.hcl'),
    (Join-Path $wimRoot 'win-hw-wim.pkr.hcl')
)) {
    if ((Get-Content $path -Raw) -match '(?i)GithubPat|github_pat|GITHUB_TOKEN|PACKER_GITHUB_API_TOKEN|\$ghToken') {
        throw "GitHub token forwarding remains in $path"
    }
    if ($path.EndsWith('.ps1')) { Read-Ast $path | Out-Null }
}
$orchestrator = Read-Ast (Join-Path $wimRoot 'bin/WinHwWim/New-WinHwWim.ps1')
$varFileWrite = $orchestrator.Find({ param($node)
    $node -is [System.Management.Automation.Language.PipelineAst] -and
    $node.Extent.Text.Contains('Set-Content -Path $varFile')
}, $true)
if (-not $varFileWrite -or $varFileWrite.Extent.Text -match '(?i)password|token|github_pat') {
    throw 'Variable file contains a credential field.'
}
$packerTry = $orchestrator.Find({ param($node)
    $node -is [System.Management.Automation.Language.TryStatementAst] -and
    $node.Body.Extent.Text.Contains('& packer init -upgrade .')
}, $true)
if (-not $packerTry) { throw 'Packer execution block not found.' }
$packerScript = [scriptblock]::Create($packerTry.Extent.Text)
$sysprep = Read-Ast (Join-Path $wimRoot 'scripts/sysprep-generalize.ps1')
$cleanup = $sysprep.EndBlock.Statements | Where-Object {
    ($_ -is [System.Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -eq '$buildSecretPaths') -or
    ($_ -is [System.Management.Automation.Language.ForEachStatementAst] -and $_.Variable.Extent.Text -in @('$answerRoot', '$secretPath'))
}
if ($cleanup.Count -ne 3) { throw 'Build secret cleanup not found.' }
$cleanupScript = [scriptblock]::Create(($cleanup.Extent.Text -join "`n"))
$autologonCheck = $sysprep.Find({ param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
    $node.Extent.Text.Contains("throw 'Build autologon password remains.'")
}, $true)
$accountCheck = $sysprep.Find({ param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
    $node.Extent.Text.Contains('throw "Disabling build account failed:')
}, $true)
if (-not $autologonCheck -or -not $accountCheck) { throw 'Pre-capture credential checks not found.' }
function Get-ItemProperty {
    if ($script:passwordRemains) { return [pscustomobject]@{ DefaultPassword = 'test secret' } }
    return [pscustomobject]@{ PSPath = 'test registry' }
}
foreach ($passwordRemains in @($false, $true)) {
    $script:passwordRemains = $passwordRemains
    $failed = $false
    try { & ([scriptblock]::Create($autologonCheck.Extent.Text)) } catch { $failed = $true }
    if ($failed -ne $passwordRemains) { throw 'Autologon cleanup check failed.' }
}
foreach ($code in @(0, 5)) {
    $global:LASTEXITCODE = $code
    $failed = $false
    try { & ([scriptblock]::Create($accountCheck.Extent.Text)) } catch { $failed = $true }
    if ($failed -ne [bool]$code) { throw 'Account disable check failed.' }
}
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('wim-secrets-' + [guid]::NewGuid())
$savedDrive = $env:SystemDrive; $savedRoot = $env:SystemRoot
$savedPassword = [Environment]::GetEnvironmentVariable('PKR_VAR_winrm_password', 'Process')
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $env:SystemDrive = $scratch; $env:SystemRoot = Join-Path $scratch 'Windows'
    $secrets = @(
        (Join-Path $scratch 'ronin/data/secrets/vault.yaml'),
        (Join-Path $scratch 'bake/run-puppet-system.ps1'),
        (Join-Path $env:SystemRoot 'Panther/unattend.xml'),
        (Join-Path $env:SystemRoot 'Panther/UnattendGC/autounattend.xml'),
        (Join-Path $env:SystemRoot 'System32/Sysprep/unattend.xml')
    )
    foreach ($path in $secrets) {
        New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
        Set-Content -LiteralPath $path -Value 'test secret'
    }
    $diagnostic = Join-Path $env:SystemRoot 'Panther/setupact.log'
    Set-Content -LiteralPath $diagnostic -Value 'keep diagnostics'
    & $cleanupScript
    foreach ($path in $secrets) { if (Test-Path -LiteralPath $path) { throw "Secret remains: $path" } }
    if (-not (Test-Path $diagnostic)) { throw 'Cleanup removed diagnostics.' }
    & $cleanupScript

    Set-Content -LiteralPath $secrets[0] -Value 'test secret'
    function Remove-Item { throw 'access denied' }
    $failed = $false
    try { & $cleanupScript } catch { $failed = $true }
    Microsoft.PowerShell.Management\Remove-Item Function:\Remove-Item -ErrorAction SilentlyContinue
    if (-not $failed) { throw 'Cleanup failure did not stop capture.' }

    function packer {
        param($Action)
        if ($env:PKR_VAR_winrm_password -ne $WinRMPassword) { throw 'Packer did not receive its password.' }
        $script:packerCalls++
        $global:LASTEXITCODE = if ($script:failAt -eq $Action) { 1 } else { 0 }
        Write-Output "mock packer $Action"
    }
    $WinRMPassword = 'test-only-build-password'
    $watchdog = $null
    $pkrLog = Join-Path $scratch 'packer.log'; $wdLog = Join-Path $scratch 'missing-watchdog.log'
    $varFile = Join-Path $scratch 'build.pkrvars.hcl'
    foreach ($prior in @($null, 'previous-test-value')) {
        foreach ($failAt in @('', 'init', 'build')) {
            $script:failAt = $failAt; $script:packerCalls = 0
            [Environment]::SetEnvironmentVariable('PKR_VAR_winrm_password', $prior, 'Process')
            $previousWinrmPassword = [Environment]::GetEnvironmentVariable('PKR_VAR_winrm_password', 'Process')
            Set-Content $varFile -Value 'image_name = "test"'
            Push-Location $scratch
            $failed = $false
            try { & $packerScript } catch { $failed = $true }
            if ($failed -ne [bool]$failAt) { throw "Unexpected Packer result: $failAt" }
            if ($script:packerCalls -ne $(if ($failAt -eq 'init') { 1 } else { 2 })) { throw 'Packer did not reach the expected phase.' }
            if (Test-Path -LiteralPath $varFile) { throw 'Packer variable file was not removed.' }
            if ([string][Environment]::GetEnvironmentVariable('PKR_VAR_winrm_password', 'Process') -cne [string]$prior) { throw 'Password environment was not restored.' }
        }
    }
}
finally {
    Microsoft.PowerShell.Management\Remove-Item Function:\Remove-Item -ErrorAction SilentlyContinue
    $env:SystemDrive = $savedDrive; $env:SystemRoot = $savedRoot
    [Environment]::SetEnvironmentVariable('PKR_VAR_winrm_password', $savedPassword, 'Process')
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $scratch -Recurse -Force
}
$global:LASTEXITCODE = 0
Write-Host 'WIM credential cleanup checks passed.'
