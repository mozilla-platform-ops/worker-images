$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$path = Join-Path $root 'provisioners/windows/win-hw-wim/scripts/bootstrap-build-host.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$definition = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Install-BuildHostTools'
}, $true)
if (-not $definition) { throw 'Build-host tool installer not found.' }

# Keep tests from changing the real machine PATH.
class BuildToolTestEnvironment {
    static [string] $MachinePath = 'existing'
    static [string] GetEnvironmentVariable([string]$Name, [string]$Target) { return [BuildToolTestEnvironment]::MachinePath }
    static [void] SetEnvironmentVariable([string]$Name, [string]$Value, [string]$Target) { [BuildToolTestEnvironment]::MachinePath = $Value }
}
. ([scriptblock]::Create($definition.Extent.Text.Replace('[Environment]', '[BuildToolTestEnvironment]')))
function Get-Command { param($Name) if ($script:available) { return $Name } }
function Invoke-WebRequest {
    param($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec)
    $script:downloads++
    if ($Uri -match 'latest|community.chocolatey.org' -or -not $Uri.StartsWith('https://') -or $TimeoutSec -ne 300) {
        throw 'Expected a versioned HTTPS download with a timeout.'
    }
    if ($script:networkFailures -gt 0) { $script:networkFailures--; throw 'download failed' }
    Set-Content -LiteralPath $OutFile -Value 'test download'
}
function Expand-Archive {
    param($Path, $DestinationPath, [switch]$Force)
    New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    if ($DestinationPath -match 'packer$') { Set-Content (Join-Path $DestinationPath 'packer.exe') 'test' }
    elseif (-not $script:missingAzCopy) {
        $nested = Join-Path $DestinationPath 'azcopy_windows_amd64_test'
        New-Item -ItemType Directory -Path $nested | Out-Null
        Set-Content (Join-Path $nested 'azcopy.exe') 'test'
    }
}
function Start-Process {
    param($FilePath, $ArgumentList, [switch]$Wait, [switch]$PassThru)
    if (-not $Wait -or -not $PassThru) { throw 'Installer must wait and return its exit code.' }
    $script:installs++
    return [pscustomobject]@{ ExitCode = $script:installerExit }
}
function Start-Sleep { }
$originalProgramFiles = $env:ProgramFiles
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('wim-tools-test-' + [guid]::NewGuid().ToString('N'))
try {
    foreach ($case in @(
        @{ name = 'fresh host'; downloads = 4; installs = 2 },
        @{ name = 'already installed'; available = $true; downloads = 0; installs = 0 },
        @{ name = 'transient download failure'; networkFailures = 1; downloads = 5; installs = 2 },
        @{ name = 'download retries exhausted'; networkFailures = 3; downloads = 3; installs = 0; failure = 'download failed' },
        @{ name = 'missing AzCopy executable'; missingAzCopy = $true; downloads = 2; installs = 0; failure = 'AzCopy archive' },
        @{ name = 'installer failure'; installerExit = 1603; downloads = 3; installs = 1; failure = 'rc=1603' },
        @{ name = 'reboot requested'; installerExit = 3010; downloads = 4; installs = 2 }
    )) {
        $env:ProgramFiles = Join-Path $testRoot $case.name
        $script:available = $case.available; $script:networkFailures = $case.networkFailures
        $script:missingAzCopy = $case.missingAzCopy
        $script:installerExit = if ($case.installerExit) { $case.installerExit } else { 0 }
        $script:downloads = 0; $script:installs = 0
        [BuildToolTestEnvironment]::MachinePath = 'existing'
        $failure = ''
        try { Install-BuildHostTools } catch { $failure = $_.Exception.Message }
        if (($case.failure -and $failure -notmatch $case.failure) -or (-not $case.failure -and $failure) -or
            $script:downloads -ne $case.downloads -or $script:installs -ne $case.installs) {
            throw "$($case.name): downloads=$script:downloads installs=$script:installs error=$failure"
        }
        $toolRoot = Join-Path $env:ProgramFiles 'WimBuildTools'
        if (Get-ChildItem $toolRoot -Directory -Filter 'stage-*') { throw 'Installer staging was not removed.' }
        if (-not $case.failure) {
            $bin = Join-Path $toolRoot 'bin'
            if ([BuildToolTestEnvironment]::MachinePath -ne "existing;$bin") { throw 'Build tool PATH was not persisted.' }
            if (-not $case.available -and (-not (Test-Path "$bin/packer.exe") -or -not (Test-Path "$bin/azcopy.exe"))) {
                throw 'Build tool executables were not installed.'
            }
        }
    }
} finally {
    $env:ProgramFiles = $originalProgramFiles
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
Write-Host 'WIM build-tool installation checks passed.'
