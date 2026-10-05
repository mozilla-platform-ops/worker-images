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
} catch {
    Write-Host $_.ScriptStackTrace
    throw
} finally { Remove-Item -LiteralPath $scratch -Recurse -Force }
Write-Host 'WIM stage routing, edition export, and existing extraction checks passed.'
