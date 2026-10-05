# Run from any directory: powershell.exe -NoProfile -File ci/test-non-ronin-pools.ps1
# Parses the deploy script and tests its functions without touching deployment disks.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$deploy = Join-Path $root 'provisioners/windows/MDC1Windows/OS-deploy.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($deploy, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($name in 'Get-DeploymentPool', 'Update-GetBoot') {
    $function = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    Invoke-Expression $function.Extent.Text
}
function Assert-Fails([scriptblock]$Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'Expected failure.' }
}
$legacy = @{ name = 'legacy'; nodes = @('nuc13-001') }
$plain = @{ name = 'a11y-win'; nodes = @('a11y-win'); ronin = $false; bootstrap_script = 'a11y-win.ps1'; image = 'win11-a11y'; secret_date = '10-05-2026' }
$pools = @($legacy, $plain)
if ((Get-DeploymentPool $pools 'nuc13-001').ronin -eq $false) { throw 'Legacy pools must default to Ronin.' }
if ((Get-DeploymentPool $pools 'a11y-win').ronin -ne $false) { throw 'Non-Ronin flag was lost.' }
Assert-Fails { Get-DeploymentPool $pools 'nuc13-00' }
Assert-Fails { Get-DeploymentPool @($plain, $plain) 'a11y-win' }
$invalid = $plain.Clone(); $invalid.ronin = 'false'
Assert-Fails { Get-DeploymentPool @($invalid) 'a11y-win' }
$invalid = $plain.Clone(); $invalid.bootstrap_script = '../bootstrap.ps1'
Assert-Fails { Get-DeploymentPool @($invalid) 'a11y-win' }

# Record the actual first-boot script selection and revision substitution.
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('non-ronin-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $local_scripts = $scratch + [IO.Path]::DirectorySeparatorChar
    function Test-Path { return $false }
    function Invoke-DownloadWithRetry {
        param($Url, $Path)
        $script:downloadUrl = $Url
        [IO.File]::WriteAllText($Path, 'WIRevisionPlaceholder')
    }
    function Set-Content {
        param($Path, $Value)
        $script:stagedScript = $Value
    }
    $revision = 'a' * 40
    $pool = $plain
    Update-GetBoot -revision $revision
    if ($script:downloadUrl -notlike "*/$revision/provisioners/windows/MDC1Windows/non-ronin/a11y-win.ps1" -or $script:stagedScript -ne $revision) {
        throw 'Non-Ronin bootstrap did not select its script from the pinned revision.'
    }
    $pool = $legacy
    Update-GetBoot -revision $revision
    if ($script:downloadUrl -notlike '*/MDC1Windows/Get-Bootstrap.ps1') { throw 'Ronin bootstrap routing changed.' }
    Remove-Item Function:\Set-Content

    # Run the real answer-file branch and verify no Ronin vault seed remains.
    $unattendXml = [xml][IO.File]::ReadAllText((Join-Path $root 'provisioners/windows/MDC1Windows/base-autounattend.xml'))
    $useRonin = $false
    $WorkerPool = 'a11y-win'
    $workerImagesRevision = $revision
    $secret_YAML = @{ win_kms_server = 'kms.example.com'; win_kms_key = 'AAAAA-BBBBB-CCCCC-DDDDD-EEEEE' }
    $branch = $ast.Find({ param($node)
        $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text -match 'if \(-not \$useRonin\)' -and $node.Extent.Text -match 'vaultCopy'
    }, $true)
    Invoke-Expression $branch.Extent.Text
    if ($unattendXml.SelectSingleNode("//*[local-name()='MetaData']/*[local-name()='Value']").InnerText -ne '1' -or
        $unattendXml.OuterXml -match 'vault.yaml' -or $unattendXml.OuterXml -notmatch 'D:\\scripts\\Get-Bootstrap.ps1') {
        throw 'Non-Ronin answer file retained Ronin seeding or selected the wrong image index.'
    }
    $stagedConfig = [IO.File]::ReadAllText((Join-Path $scratch 'non-ronin.json')) | ConvertFrom-Json
    if ($stagedConfig.pool -ne $WorkerPool -or $stagedConfig.worker_images_revision -ne $revision -or
        $stagedConfig.PSObject.Properties.Name -contains 'win_adminpw') { throw 'Incorrect staged non-Ronin configuration.' }
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
    Remove-Item Function:\Test-Path
}

# Exercise the native KMS sequence with fakes, including activation that returns
# zero but leaves Windows unlicensed. No installer, registry, or file deletion runs.
$bootstrap = Join-Path $root 'provisioners/windows/MDC1Windows/non-ronin/a11y-win.ps1'
$code = [IO.File]::ReadAllText($bootstrap)
$script:configJson = '{"pool":"a11y-win","kms_server":"kms.example.com:1688","kms_key":"AAAAA-BBBBB-CCCCC-DDDDD-EEEEE","worker_images_revision":"test"}'
function Get-Content { return $script:configJson }
function cscript.exe {
    $script:kmsCalls += ,@($args)
    $global:LASTEXITCODE = $script:nativeExitCode
}
function Get-CimInstance { return [pscustomobject]@{ LicenseStatus = $script:licenseStatus } }
function Test-Path { return $true }
function Remove-Item { $script:cleanupCount++ }
function Get-ChildItem { return @() }
function Set-ItemProperty { }
function Remove-ItemProperty { }
$script:nativeExitCode = 0; $script:licenseStatus = 1
$script:kmsCalls = @(); $script:cleanupCount = 0
& ([scriptblock]::Create($code))
if ($script:kmsCalls.Count -ne 3 -or $script:kmsCalls[0][2] -ne '/ipk' -or
    $script:kmsCalls[1][2] -ne '/skms' -or $script:kmsCalls[2][2] -ne '/ato' -or $script:cleanupCount -eq 0) {
    throw 'KMS command sequence or successful cleanup failed.'
}
$script:cleanupCount = 0; $script:nativeExitCode = 1
Assert-Fails { & ([scriptblock]::Create($code)) }
if ($script:cleanupCount -ne 0) { throw 'Credentials were deleted after a failed KMS command.' }
$script:nativeExitCode = 0; $script:licenseStatus = 0
Assert-Fails { & ([scriptblock]::Create($code)) }
if ($script:cleanupCount -ne 0) { throw 'Credentials were deleted while Windows remained unlicensed.' }
Write-Host 'Non-Ronin pool and KMS checks passed.'
