# Local checks: no Azure calls, mounted media, or Windows servicing.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Assert-Fails([scriptblock]$Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'Expected failure.' }
}
# Run the actual stage-selection statement from the orchestrator.
$tokens = $null; $errors = $null
$orchestrator = Join-Path $root 'provisioners/windows/win-hw-wim/bin/WinHwWim/New-WinHwWim.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($orchestrator, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$selection = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and $node.Extent.Text -match "ContainsKey\('Stages'\)"
}, $true).Extent.Text
$PSBoundParameters.Clear()
foreach ($case in @(
    @{ iso = $false; plain = $false; expected = 'prep,build,publish' },
    @{ iso = $true; plain = $false; expected = 'iso' },
    @{ iso = $false; plain = $true; expected = 'plain,publish' }
)) {
    $isoEnabled = $case.iso; $plainWim = $case.plain
    Invoke-Expression $selection
    if (($Stages -join ',') -ne $case.expected) { throw 'Incorrect config-driven WIM stages.' }
}
$PSBoundParameters['Stages'] = @('publish')
$Stages = @('publish')
Invoke-Expression $selection
if (($Stages -join ',') -ne 'publish') { throw 'Explicit stage override changed.' }

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('wim-pool-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $scratch | Out-Null
$plainStage = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.IfStatementAst] -and
    $node.Extent.Text.StartsWith("if (`$Stages -contains 'plain')") -and
    $node.Extent.Text.Contains("& `$ps 'extract-wim-from-iso.ps1'")
}, $true)
$ps = { param($File, $Arguments) $script:stageCalls += ,@($File, $Arguments) }
$Stages = @('plain', 'publish'); $work = $scratch; $baseIso = 'source.iso'; $baseCont = 'resources'
$baseIsoBlob = 'ISOs/source.iso'; $goldenWim = Join-Path $scratch 'golden.wim'; $edition = 'Windows 11 Pro'
$account = 'hardwareimaging'; $Image = 'win11-26h2-a11y'; $BuildId = 'test'; $sbomMd = Join-Path $scratch 'provenance.md'
$drvCabUrls = @('https://example.com/first.zip', 'https://example.com/second.cab')
foreach ($drvInject in $true, $false) {
    $script:stageCalls = @()
    Invoke-Expression $plainStage.Extent.Text
    $arguments = $script:stageCalls[1][1]
    if ($drvInject -and $arguments[-1] -ne ($drvCabUrls -join '|')) { throw 'Plain stage did not pass the configured driver packs.' }
    if (-not $drvInject -and $arguments -contains '-DriverCabUrls') { throw 'Drivers enabled for an unconfigured plain WIM.' }
}
$extract = Join-Path $root 'provisioners/windows/win-hw-wim/scripts/extract-wim-from-iso.ps1'
$sourceIso = Join-Path $scratch 'source.iso'
$outWim = Join-Path $scratch 'install.wim'
[IO.File]::WriteAllText($sourceIso, 'fake ISO')
function Mount-DiskImage { return [pscustomobject]@{ Mounted = $true } }
function Get-Volume { return [pscustomobject]@{ DriveLetter = 'X' } }
function Dismount-DiskImage { $global:wimPoolTestDismounts++ }
function Test-Path {
    param($LiteralPath, $Path)
    if ($LiteralPath -eq 'X:\sources\install.wim') { return $global:wimPoolTestSourceType -eq 'wim' }
    if ($LiteralPath -eq 'X:\sources\install.esd') { return $global:wimPoolTestSourceType -eq 'esd' }
    if (-not $LiteralPath) { $LiteralPath = $Path }
    return [IO.File]::Exists($LiteralPath) -or [IO.Directory]::Exists($LiteralPath)
}
function Get-WindowsImage {
    param($ImagePath)
    if ($ImagePath -eq $outWim) { return [pscustomobject]@{ ImageIndex = 1; ImageName = 'Windows 11 Enterprise' } }
    return @([pscustomobject]@{ ImageIndex = 1; ImageName = 'Windows 11 Pro' },
        [pscustomobject]@{ ImageIndex = 3; ImageName = 'Windows 11 Enterprise' })
}
function Export-WindowsImage {
    param($SourceImagePath, $SourceIndex, $DestinationImagePath, $CompressionType, [switch]$CheckIntegrity)
    $global:wimPoolTestExports += ,@($SourceImagePath, $SourceIndex)
    [IO.File]::WriteAllText($DestinationImagePath, 'exported WIM')
}
function Copy-Item {
    param($LiteralPath, $Destination, [switch]$Force)
    $global:wimPoolTestCopies++
    [IO.File]::WriteAllText($Destination, 'copied multi-edition WIM')
}
function Get-FileHash {
    param($LiteralPath, $Algorithm)
    # The Windows Get-FileHash script uses Test-Path internally; keep its file
    # hashing independent of the mocked mounted-media paths above.
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [pscustomobject]@{ Hash = [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($LiteralPath))).Replace('-', '') } }
    finally { $sha.Dispose() }
}
function Mount-WindowsImage {
    param($ImagePath, $Index, $Path, [switch]$CheckIntegrity)
    if ($Index -ne 1 -or -not $CheckIntegrity) { throw 'Driver servicing must mount index 1 with integrity checks.' }
    $global:wimPoolTestMountedWim = $ImagePath
    $global:wimPoolTestMounts++
}
function Dismount-WindowsImage {
    param($Path, [switch]$Save, [switch]$Discard, [switch]$CheckIntegrity)
    if ($Save) {
        if (-not $CheckIntegrity) { throw 'Driver servicing must save with integrity checks.' }
        if ($global:wimPoolTestSaveFails) { throw 'Mock commit failure.' }
        [IO.File]::WriteAllText($global:wimPoolTestMountedWim, 'serviced WIM')
        $global:wimPoolTestSaves++
    }
    elseif ($Discard) { $global:wimPoolTestDiscards++ }
    else { throw 'WIM dismount must save or discard.' }
}
function azcopy {
    if ($args[0] -ne 'copy') { throw 'Expected authenticated blob copy.' }
    $global:wimPoolTestPackDirectory = Split-Path -Parent (Split-Path -Parent $args[2])
    [IO.File]::WriteAllBytes($args[2], $global:wimPoolTestZip)
    $global:LASTEXITCODE = $global:wimPoolTestDownloadExitCode
}
function Invoke-WebRequest {
    param($Uri, $OutFile, [switch]$UseBasicParsing)
    [IO.File]::WriteAllBytes($OutFile, $global:wimPoolTestZip)
}
function expand.exe {
    [IO.File]::WriteAllText((Join-Path $args[-1] 'network.inf'), '[Version]')
    $global:LASTEXITCODE = $global:wimPoolTestExpandExitCode
}
function dism.exe {
    if ($args -notcontains '/Add-Driver' -or $args -notcontains '/Recurse' -or $args -contains '/ForceUnsigned') {
        throw 'Driver injection must recurse and retain signature enforcement.'
    }
    $directory = ($args | Where-Object { $_ -like '/Driver:*' }) -replace '^/Driver:', ''
    if (@(Get-ChildItem -LiteralPath $directory -Filter '*.inf' -Recurse -File).Count -ne $global:wimPoolTestExpectedInfs) { throw 'Driver packs were not extracted into separate directories.' }
    $global:wimPoolTestDriverCalls++
    $global:LASTEXITCODE = $global:wimPoolTestDriverExitCode
}
$oldAzcopyLogin = $env:AZCOPY_AUTO_LOGIN_TYPE
try {
    $global:wimPoolTestDismounts = 0; $global:wimPoolTestCopies = 0
    foreach ($type in 'wim', 'esd') {
        $global:wimPoolTestSourceType = $type; $global:wimPoolTestExports = @()
        & $extract -SourceIso $sourceIso -OutWim $outWim -Edition 'Windows 11 Enterprise'
        if ($global:wimPoolTestExports.Count -ne 1 -or $global:wimPoolTestExports[0][1] -ne 3 -or $global:wimPoolTestCopies -ne 0) { throw 'Wrong edition was exported.' }
        $hash = (Get-FileHash -LiteralPath $outWim).Hash.ToLower()
        if (-not ([IO.File]::ReadAllText("$outWim.sha256").StartsWith($hash))) { throw 'WIM SHA-256 sidecar is incorrect.' }
    }
    Assert-Fails { & $extract -SourceIso $sourceIso -OutWim $outWim -Edition 'Unavailable edition' }
    if ($global:wimPoolTestDismounts -ne 3) { throw 'ISO was not dismounted on export failure.' }
    $global:wimPoolTestSourceType = 'wim'; $global:wimPoolTestExports = @()
    & $extract -SourceIso $sourceIso -OutWim $outWim
    if ($global:wimPoolTestCopies -ne 1 -or $global:wimPoolTestExports.Count -ne 0) { throw 'Original multi-edition WIM extraction changed.' }
    $global:wimPoolTestSourceType = 'esd'; $global:wimPoolTestExports = @()
    & $extract -SourceIso $sourceIso -OutWim $outWim
    if ($global:wimPoolTestExports.Count -ne 2) { throw 'Original all-edition ESD extraction changed.' }

    # Use a real ZIP extraction; only download and native Windows servicing are mocked.
    $driverInf = Join-Path $scratch 'network.inf'
    [IO.File]::WriteAllText($driverInf, '[Version]')
    $driverZip = Join-Path $scratch 'drivers.zip'
    Compress-Archive -LiteralPath $driverInf -DestinationPath $driverZip
    $global:wimPoolTestZip = [IO.File]::ReadAllBytes($driverZip)
    $global:wimPoolTestExpectedInfs = 1; $global:wimPoolTestDownloadExitCode = 0; $global:wimPoolTestExpandExitCode = 0
    $global:wimPoolTestMounts = 0; $global:wimPoolTestSaves = 0; $global:wimPoolTestDiscards = 0
    $global:wimPoolTestDriverCalls = 0; $global:wimPoolTestDriverExitCode = 0
    $packUrl = 'https://hardwareimaging.blob.core.windows.net/resources/drivers/test.zip'
    & $extract -SourceIso $sourceIso -OutWim $outWim -Edition 'Windows 11 Enterprise' -DriverCabUrls $packUrl
    if ($global:wimPoolTestSaves -ne 1 -or $global:wimPoolTestDriverCalls -ne 1) { throw 'Plain WIM driver servicing was skipped.' }
    if (Test-Path -LiteralPath $global:wimPoolTestPackDirectory) { throw 'Driver staging directory leaked.' }
    $servicedHash = (Get-FileHash -LiteralPath $outWim).Hash.ToLower()
    if (-not ([IO.File]::ReadAllText("$outWim.sha256").StartsWith($servicedHash))) { throw 'Checksum was computed before driver injection.' }
    $global:wimPoolTestDriverExitCode = 1
    Assert-Fails { & $extract -SourceIso $sourceIso -OutWim $outWim -Edition 'Windows 11 Enterprise' -DriverCabUrls $packUrl }
    if ($global:wimPoolTestDiscards -ne 1 -or $global:wimPoolTestSaves -ne 1) { throw 'Failed driver injection was not discarded.' }
    if (Test-Path -LiteralPath $global:wimPoolTestPackDirectory) { throw 'Driver staging directory leaked on failure.' }
    $global:wimPoolTestDriverExitCode = 0; $global:wimPoolTestSaveFails = $true
    Assert-Fails { & $extract -SourceIso $sourceIso -OutWim $outWim -Edition 'Windows 11 Enterprise' -DriverCabUrls $packUrl }
    if ($global:wimPoolTestDiscards -ne 2) { throw 'Failed WIM commit was not discarded.' }
    $global:wimPoolTestSaveFails = $false
    Assert-Fails { & $extract -SourceIso $sourceIso -OutWim $outWim -DriverCabUrls $packUrl }
    if ($global:wimPoolTestMounts -ne 3) { throw 'Invalid driver request mounted a WIM.' }

    . (Join-Path $root 'provisioners/windows/win-hw-wim/scripts/offline-drivers.ps1')
    $global:wimPoolTestExpectedInfs = 2
    Add-OfflineDrivers -ImagePath 'W:\' -DriverCabUrls "$packUrl|https://example.com/second.cab"
    $global:wimPoolTestExpectedInfs = 1; $callsBefore = $global:wimPoolTestDriverCalls
    $global:wimPoolTestExpandExitCode = 1
    Assert-Fails { Add-OfflineDrivers -ImagePath 'W:\' -DriverCabUrls 'https://example.com/failing.cab' }
    $global:wimPoolTestExpandExitCode = 0; $global:wimPoolTestDownloadExitCode = 1
    Assert-Fails { Add-OfflineDrivers -ImagePath 'W:\' -DriverCabUrls $packUrl }
    $global:wimPoolTestDownloadExitCode = 0
    Assert-Fails { Add-OfflineDrivers -ImagePath 'W:\' -DriverCabUrls 'https://example.com/unsupported.exe' }
    $emptyZip = Join-Path $scratch 'empty.zip'
    Compress-Archive -LiteralPath $sourceIso -DestinationPath $emptyZip
    $global:wimPoolTestZip = [IO.File]::ReadAllBytes($emptyZip)
    Assert-Fails { Add-OfflineDrivers -ImagePath 'W:\' -DriverCabUrls $packUrl }
    if ($global:wimPoolTestDriverCalls -ne $callsBefore) { throw 'Invalid driver packs reached DISM.' }
    if (Test-Path -LiteralPath $global:wimPoolTestPackDirectory) { throw 'Failed download or extraction leaked driver staging.' }
} catch {
    Write-Host $_.ScriptStackTrace
    throw
} finally {
    $env:AZCOPY_AUTO_LOGIN_TYPE = $oldAzcopyLogin
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
Write-Host 'WIM stage routing, edition export, driver injection/cleanup, and checksum checks passed.'
