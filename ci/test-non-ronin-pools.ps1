# Run from any directory: powershell.exe -NoProfile -File ci/test-non-ronin-pools.ps1
# Parses the deploy script and tests its functions without touching deployment disks.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$deploy = Join-Path $root 'provisioners/windows/MDC1Windows/OS-deploy.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($deploy, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
# Keep every original deployment function byte-for-byte (apart from line endings).
$baseline = (& git -C $root show '47ce934d:provisioners/windows/MDC1Windows/OS-deploy.ps1') -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'Could not load the original deployment script.' }
$baseAst = [System.Management.Automation.Language.Parser]::ParseInput($baseline, [ref]$tokens, [ref]$errors)
foreach ($original in $baseAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    $current = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $original.Name }, $true)
    if (-not $current -or ($current.Extent.Text -replace "`r", '') -cne ($original.Extent.Text -replace "`r", '')) {
        throw "Existing deployment function changed: $($original.Name)"
    }
}
$loopPredicate = { param($node) $node -is [System.Management.Automation.Language.ForEachStatementAst] -and $node.Extent.Text.StartsWith('foreach ($pool in $YAML.pools)') }
$originalLoop = $baseAst.Find($loopPredicate, $true).Extent.Text -replace "`r", ''
$currentLoop = $ast.Find($loopPredicate, $true).Extent.Text -replace "`r", ''
$currentLoop = $currentLoop.Replace('    if ($pool.ronin -eq $false -or $pool.ronin.enabled -eq $false) { continue }' + "`n", '')
if ($currentLoop -cne $originalLoop) { throw 'Existing pool matching/fallback/development behavior changed.' }
if ($ast.Extent.Text -notmatch '(?s)if \(\$useRonin\) \{\s+Update-GetBoot -revision \$workerImagesRevision\s+\}') {
    throw 'Existing Ronin bootstrap call must remain guarded in its original position.'
}
foreach ($name in 'Get-NonRoninDeploymentPool', 'Update-NonRoninBoot', 'Update-GetBoot') {
    $function = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    Invoke-Expression $function.Extent.Text
}
function Assert-Fails([scriptblock]$Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'Expected failure.' }
}
$legacy = @{ name = 'legacy'; nodes = @('nuc13-001') }
$plain = @{ name = 'win11-26h2-a11y'; nodes = @('a11y', 'a11y-win'); ronin = @{ enabled = $false }; image = 'win11-a11y'; secret_date = '10-05-2026' }
$pools = @($legacy, $plain)
$other = $plain.Clone(); $other.name = 'win11-lab'; $other.nodes = @('lab-win')
if ((Get-NonRoninDeploymentPool @($legacy, $plain, $other) 'lab-win').name -ne 'win11-lab') {
    throw 'Non-Ronin routing must support another pool using the shared bootstrap.'
}
if ($null -ne (Get-NonRoninDeploymentPool $pools 'nuc13-001')) { throw 'Legacy pools must bypass the new selector.' }
if ((Get-NonRoninDeploymentPool $pools 'a11y-win').ronin.enabled -ne $false) { throw 'Non-Ronin flag was lost.' }
if ((Get-NonRoninDeploymentPool $pools 'a11y').name -ne 'win11-26h2-a11y') { throw 'The DNS shortname a11y must select the accessibility pool.' }
if ($null -ne (Get-NonRoninDeploymentPool $pools 'a11y-other')) { throw 'Accessibility host matching must remain exact.' }
if ($null -ne (Get-NonRoninDeploymentPool $pools 'nuc13-00')) { throw 'Unmatched nodes must not select a non-Ronin pool.' }
if ($null -ne (Get-NonRoninDeploymentPool @($legacy, $legacy) 'nuc13-001')) { throw 'Legacy matching rules were overridden.' }
Assert-Fails { Get-NonRoninDeploymentPool @($plain, $plain) 'a11y-win' }
$invalid = $plain.Clone(); $invalid.ronin = @{ enabled = 'false' }
Assert-Fails { Get-NonRoninDeploymentPool @($invalid) 'a11y-win' }
$invalid = $plain.Clone(); $invalid.ronin = @{ enabled = $true }
if ($null -ne (Get-NonRoninDeploymentPool @($invalid) 'a11y-win')) { throw 'Enabled Ronin pool must bypass non-Ronin provisioning.' }
$invalid = $plain.Clone(); $invalid.name = '../bootstrap'
Assert-Fails { Get-NonRoninDeploymentPool @($invalid) 'a11y-win' }

$kmsValidation = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
    $node.Extent.Text.StartsWith('if ([string]$sourceSecrets.win_kms_key') -and
    $node.Extent.Text.Contains('Non-Ronin deployment secrets require a valid win_kms_key')
}, $true)
if (-not $kmsValidation) { throw 'Missing pre-disk KMS validation.' }
$sourceSecrets = @{ win_kms_key = 'W269N-WFGWX-YVC9B-4J6C9-T83GX'; win_kms_server = 'kms.example.com:1688' }
Invoke-Expression $kmsValidation.Extent.Text
foreach ($field in 'win_kms_key', 'win_kms_server') {
    $valid = $sourceSecrets.Clone()
    foreach ($value in $null, '', 'bad value') {
        $sourceSecrets[$field] = $value
        Assert-Fails { Invoke-Expression $kmsValidation.Extent.Text }
    }
    $sourceSecrets = $valid
}

$withoutSecrets = $plain.Clone(); $withoutSecrets.Remove('secret_date')
if ($null -eq (Get-NonRoninDeploymentPool @($withoutSecrets) 'a11y-win')) { throw 'secret_date must be optional.' }
$invalid = $plain.Clone(); $invalid.secret_date = '../secret'
Assert-Fails { Get-NonRoninDeploymentPool @($invalid) 'a11y-win' }
foreach ($image in $null, '', ' ', '../Images') {
    $invalid = $plain.Clone(); $invalid.image = $image
    Assert-Fails { Get-NonRoninDeploymentPool @($invalid) 'a11y-win' }
}

# Run the actual selection guards without executing partitioning or deployment.
$guards = @($ast.EndBlock.Statements | Where-Object {
    $_ -is [System.Management.Automation.Language.IfStatementAst] -and
    $_.Extent.Text -match 'refusing to partition or copy images'
})
if ($guards.Count -ne 2) { throw 'Expected pool and image guards before disk operations.' }
$guardCode = [scriptblock]::Create(($guards.Extent.Text -join "`n"))
$useRonin = $true; $found = $false; $neededImage = 'valid-image'; $shortname = 'unknown-node'
Assert-Fails { & $guardCode }
$found = $true; $neededImage = ''
Assert-Fails { & $guardCode }
$neededImage = 'win11-26h2-a11y-20261006-045741'
& $guardCode
$useRonin = $false; $found = $false
& $guardCode
$diskStart = $ast.Extent.Text.IndexOf('Write-Host "Preparing local environment."')
if ($guards[-1].Extent.StartOffset -ge $diskStart) { throw 'Selection must fail before disk operations.' }

# Exercise the real optional refresh branch; no files are copied by the mock.
$refresh = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
    $node.Extent.Text.StartsWith('if ($hasPoolSecrets)') -and
    $node.Extent.Text.Contains('Copy-Item -Path $source_secrets')
}, $true)
if (-not $refresh) { throw 'Pool secret copy must be conditional.' }
function Copy-Item { param($Path, $Destination, [switch]$Force, $ErrorAction) $script:secretCopies++ }
$source_secrets = 'source.yaml'; $secret_file = 'destination.yaml'
$script:secretCopies = 0; $hasPoolSecrets = $false
Invoke-Expression $refresh.Extent.Text
if ($script:secretCopies -ne 0) { throw 'Copied pool secrets without secret_date.' }
$hasPoolSecrets = $true
Invoke-Expression $refresh.Extent.Text
if ($script:secretCopies -ne 1) { throw 'Dated pool secrets were not refreshed.' }
Remove-Item Function:\Copy-Item

# Record the actual first-boot script selection and revision substitution.
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('non-ronin-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $local_scripts = $scratch + [IO.Path]::DirectorySeparatorChar
    function Test-Path {
        param($LiteralPath, $Path, $PathType)
        return $LiteralPath -eq (Join-Path $local_scripts 'Get-Bootstrap.ps1')
    }
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
    foreach ($pool in @($plain, $other)) {
        Update-NonRoninBoot -revision $revision
        if ($script:downloadUrl -cne "https://raw.githubusercontent.com/mozilla-platform-ops/worker-images/$revision/provisioners/windows/MDC1Windows/non-ronin/$($pool.name).ps1") {
            throw 'Non-Ronin bootstrap did not select the pool-named script from the pinned revision.'
        }
    }
    $pool = $legacy
    Update-GetBoot -revision $revision
    if ($script:downloadUrl -notlike '*/MDC1Windows/Get-Bootstrap.ps1' -or $script:stagedScript -ne $revision) { throw 'Ronin bootstrap routing changed.' }
    Remove-Item Function:\Set-Content

    # Run the real answer-file branch and verify no Ronin vault seed remains.
    $unattendXml = [xml][IO.File]::ReadAllText((Join-Path $root 'provisioners/windows/MDC1Windows/base-autounattend.xml'))
    $useRonin = $false
    $WorkerPool = 'win11-26h2-a11y'
    $workerImagesRevision = $revision
    $pool = $plain
    $secret_YAML = @{ win_kms_server = 'kms.example.com'; win_kms_key = 'W269N-WFGWX-YVC9B-4J6C9-T83GX' }
    $passwordBranch = $ast.Find({ param($node)
        $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text.StartsWith('if ([string]::IsNullOrWhiteSpace($adminPassword))')
    }, $true)
    if (-not $passwordBranch) { throw 'Missing answer-file password handling.' }
    $adminPassword = ''
    Invoke-Expression $passwordBranch.Extent.Text
    if ($unattendXml.OuterXml -match 'NotARealPassword' -or
        $unattendXml.SelectNodes("//*[local-name()='UserAccounts' or local-name()='AutoLogon']").Count -ne 0) {
        throw 'Password-free setup retained default accounts, passwords, or autologon.'
    }
    $useRonin = $true
    Assert-Fails { Invoke-Expression $passwordBranch.Extent.Text }
    $useRonin = $false
    $withoutPassword = $unattendXml
    $unattendXml = [xml][IO.File]::ReadAllText((Join-Path $root 'provisioners/windows/MDC1Windows/base-autounattend.xml'))
    $adminPassword = 'test<&password'
    Invoke-Expression $passwordBranch.Extent.Text
    $values = $unattendXml.SelectNodes("//*[local-name()='Password' or local-name()='AdministratorPassword']/*[local-name()='Value']")
    if ($values.Count -ne 3 -or @($values | Where-Object { $_.InnerText -cne $adminPassword }).Count -ne 0) {
        throw 'Configured password was not preserved safely in the answer file.'
    }
    $unattendXml = $withoutPassword
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
    if ($stagedConfig.kms_key -ne $secret_YAML.win_kms_key -or $stagedConfig.pool -ne $WorkerPool -or $stagedConfig.worker_images_revision -ne $revision -or
        $stagedConfig.PSObject.Properties.Name -contains 'win_adminpw') { throw 'Incorrect staged non-Ronin configuration.' }

    # Ronin keeps the template's vault seed, image index, and account/autologon settings.
    $useRonin = $true
    $unattendXml = [xml][IO.File]::ReadAllText((Join-Path $root 'provisioners/windows/MDC1Windows/base-autounattend.xml'))
    Invoke-Expression $passwordBranch.Extent.Text
    $roninXml = $unattendXml.OuterXml
    if ($unattendXml.SelectNodes("//*[local-name()='UserAccounts' or local-name()='AutoLogon']").Count -ne 2 -or
        $unattendXml.OuterXml -notmatch 'vault.yaml') { throw 'Ronin account or vault settings were removed.' }
    if (@($unattendXml.SelectNodes("//*[local-name()='Password' or local-name()='AdministratorPassword']/*[local-name()='Value']") |
        Where-Object { $_.InnerText -cne $adminPassword }).Count -ne 0) { throw 'Ronin password was not populated safely.' }
    Invoke-Expression $branch.Extent.Text
    if ($unattendXml.OuterXml -cne $roninXml) { throw 'Non-Ronin customization changed the Ronin answer file.' }
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
    Remove-Item Function:\Test-Path
}

# Exercise the native KMS sequence with fakes, including activation that returns
# zero but leaves Windows unlicensed. No installer, registry, or file deletion runs.
$global:nonRoninTest = @{}
$bootstrap = Join-Path $root 'provisioners/windows/MDC1Windows/non-ronin/win11-26h2-a11y.ps1'
$global:nonRoninTest.configJson = '{"pool":"win11-26h2-a11y","kms_server":"kms.example.com:1688","kms_key":"AAAAA-BBBBB-CCCCC-DDDDD-EEEEE","worker_images_revision":"test"}'
function Get-Content {
    param($LiteralPath, [switch]$Raw)
    if ($LiteralPath -eq 'C:\mozilla-build\VERSION') { return '4.2.1' }
    return $global:nonRoninTest.configJson
}
function cscript.exe {
    $global:nonRoninTest.kmsCalls += ,@($args)
    $global:LASTEXITCODE = $global:nonRoninTest.nativeExitCode
}
function Get-CimInstance { return [pscustomobject]@{ LicenseStatus = $global:nonRoninTest.licenseStatus } }
function Invoke-WebRequest {
    param([switch]$UseBasicParsing, $Uri, $OutFile, $TimeoutSec)
    if ($global:nonRoninTest.downloadFails) { throw 'Mock download failure.' }
    $global:nonRoninTest.mozillaBuildUrl = $Uri
}
function Get-AuthenticodeSignature {
    param($LiteralPath)
    return [pscustomobject]@{ Status = $global:nonRoninTest.signatureStatus; SignerCertificate = [pscustomobject]@{ Subject = $global:nonRoninTest.signerSubject } }
}
function Start-Process {
    param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru)
    if ($ArgumentList -ne '/S' -or -not $Wait -or -not $PassThru) { throw 'MozillaBuild must install silently and wait for its exit code.' }
    $global:nonRoninTest.installerCalls++
    return [pscustomobject]@{ ExitCode = $global:nonRoninTest.installerExitCode }
}
function Test-Path {
    param($LiteralPath, $PathType)
    if ($LiteralPath -like 'C:\mozilla-build\*') { return $global:nonRoninTest.mozillaBuildInstalled }
    return $true
}
function Remove-Item { $global:nonRoninTest.cleanupCount++ }
function Get-ChildItem { return @() }
function Set-ItemProperty { }
function Remove-ItemProperty { }
$global:nonRoninTest.nativeExitCode = 0; $global:nonRoninTest.licenseStatus = 1
$global:nonRoninTest.signatureStatus = 'Valid'; $global:nonRoninTest.signerSubject = 'CN=Mozilla Corporation, O=Mozilla Corporation'
$global:nonRoninTest.installerExitCode = 0; $global:nonRoninTest.mozillaBuildInstalled = $true
foreach ($poolName in 'win11-26h2-a11y', 'win11-lab') {
    $config = $global:nonRoninTest.configJson | ConvertFrom-Json
    $config.pool = $poolName
    $global:nonRoninTest.configJson = $config | ConvertTo-Json
    $global:nonRoninTest.kmsCalls = @(); $global:nonRoninTest.cleanupCount = 0
    $global:nonRoninTest.installerCalls = 0
    & $bootstrap
    if ($global:nonRoninTest.kmsCalls.Count -ne 3 -or $global:nonRoninTest.kmsCalls[0][2] -ne '/ipk' -or
        $global:nonRoninTest.kmsCalls[1][2] -ne '/skms' -or $global:nonRoninTest.kmsCalls[2][2] -ne '/ato' -or $global:nonRoninTest.cleanupCount -eq 0) {
        throw 'KMS command sequence or successful cleanup failed.'
    }
    if ($global:nonRoninTest.installerCalls -ne 1 -or $global:nonRoninTest.mozillaBuildUrl -ne 'https://ftp.mozilla.org/pub/mozilla/libraries/win32/MozillaBuildSetup-Latest.exe') {
        throw 'MozillaBuild was not installed from the official latest-release URL.'
    }
}
$global:nonRoninTest.cleanupCount = 0; $global:nonRoninTest.nativeExitCode = 1
Assert-Fails { & $bootstrap }
if ($global:nonRoninTest.cleanupCount -ne 0) { throw 'Credentials were deleted after a failed KMS command.' }
$global:nonRoninTest.nativeExitCode = 0; $global:nonRoninTest.licenseStatus = 0
Assert-Fails { & $bootstrap }
if ($global:nonRoninTest.cleanupCount -ne 0) { throw 'Credentials were deleted while Windows remained unlicensed.' }
$global:nonRoninTest.licenseStatus = 1; $global:nonRoninTest.installerCalls = 0
$global:nonRoninTest.downloadFails = $true
Assert-Fails { & $bootstrap }
$global:nonRoninTest.downloadFails = $false
foreach ($status in 'NotSigned', 'HashMismatch') {
    $global:nonRoninTest.signatureStatus = $status
    Assert-Fails { & $bootstrap }
}
$global:nonRoninTest.signatureStatus = 'Valid'; $global:nonRoninTest.signerSubject = 'CN=Other Publisher'
Assert-Fails { & $bootstrap }
if ($global:nonRoninTest.installerCalls -ne 0 -or $global:nonRoninTest.cleanupCount -ne 0) { throw 'Untrusted installer executed or credentials were removed.' }
$global:nonRoninTest.signerSubject = 'CN=Mozilla Corporation, O=Mozilla Corporation'
$global:nonRoninTest.installerExitCode = 1
Assert-Fails { & $bootstrap }
$global:nonRoninTest.installerExitCode = 0; $global:nonRoninTest.mozillaBuildInstalled = $false
Assert-Fails { & $bootstrap }
if ($global:nonRoninTest.cleanupCount -ne 0) { throw 'Credentials were deleted after MozillaBuild installation failed.' }
Write-Host 'Non-Ronin pool, KMS, and MozillaBuild checks passed.'
Remove-Variable nonRoninTest -Scope Global
