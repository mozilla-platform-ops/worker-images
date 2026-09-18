# Local helper checks: no software is installed and no Azure resources are used.
# Run from the repository root: pwsh -File ci/test-foofrix-bootstrap.ps1
$ErrorActionPreference = 'Stop'
. ./scripts/windows/foofrix/bootstrap-helpers.ps1

function Assert-Fails {
    param ([scriptblock] $Action)
    $failed = $false
    try { & $Action } catch { $failed = $true }
    if (-not $failed) { throw 'Expected the operation to fail' }
}

# Replace external installers with recording fakes for these checks.
function Start-Process {
    param ($FilePath, $ArgumentList, [switch] $Wait, [switch] $PassThru, [switch] $NoNewWindow)
    $script:installer = $FilePath
    $script:installerArguments = $ArgumentList
    if (-not ($Wait -and $PassThru)) { throw 'Installer must be awaited' }
    return [pscustomobject]@{ ExitCode = $script:fakeExitCode }
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('foofrix-helper-test-' + [guid]::NewGuid())
New-Item -ItemType Directory $scratch | Out-Null
try {
    $msi = Join-Path $scratch 'tool with spaces.msi'
    $exe = Join-Path $scratch 'tool.exe'
    Set-Content $msi 'fake'
    Set-Content $exe 'fake'
    $script:fakeExitCode = 0
    Install-BuildInstaller -Path $msi -Arguments 'ALLUSERS=1'
    if ($script:installer -ne 'msiexec.exe' -or $script:installerArguments -ne "/i `"$msi`" /qn /norestart ALLUSERS=1") {
        throw 'MSI quoting or silent switches are incorrect'
    }
    $script:fakeExitCode = 3010
    Install-BuildInstaller -Path $exe -Arguments '/quiet /norestart'
    if ($script:installer -ne $exe -or $script:installerArguments -ne '/quiet /norestart') {
        throw 'EXE arguments were not preserved'
    }
    $script:fakeExitCode = 1603
    Assert-Fails { Install-BuildInstaller -Path $exe }
    Assert-Fails { Install-BuildInstaller -Path (Join-Path $scratch 'missing.msi') }

    $file = Join-Path $scratch 'source.txt'
    $zip = Join-Path $scratch 'source.zip'
    $destination = Join-Path $scratch 'expanded'
    Set-Content $file 'source contents'
    Compress-Archive -LiteralPath $file -DestinationPath $zip
    Expand-BuildArchive -Path $zip -Destination $destination
    if ((Get-Content (Join-Path $destination 'source.txt')) -ne 'source contents') {
        throw 'Archive content was not extracted'
    }
    Assert-Fails { Expand-BuildArchive -Path (Join-Path $scratch 'missing.zip') -Destination $destination }

    $steps = ConvertFrom-Json @"
[
  { "action": "install", "artifact": "tool {suffix}.msi", "arguments": "OWNER={owner}" },
  { "action": "extract", "artifact": "source.zip", "destination": "$($destination.Replace('\', '\\'))" }
]
"@
    $script:fakeExitCode = 0
    $variables = '{"suffix":"with spaces","owner":"all"}' | ConvertFrom-Json
    Invoke-BuildRecipe -Steps $steps -ArtifactDirectory $scratch -Variables $variables
    if ($script:installer -ne 'msiexec.exe' -or $script:installerArguments -notlike '*OWNER=all' -or
        -not (Test-Path (Join-Path $destination 'source.txt'))) {
        throw 'Build recipe did not dispatch its install and extract steps'
    }
    $invalid = '[{"action":"run","artifact":"tool.exe"}]' | ConvertFrom-Json
    Assert-Fails { Invoke-BuildRecipe -Steps $invalid -ArtifactDirectory $scratch -Variables $variables }
    $invalid = '[{"action":"install","artifact":"../tool.exe"}]' | ConvertFrom-Json
    Assert-Fails { Invoke-BuildRecipe -Steps $invalid -ArtifactDirectory $scratch -Variables $variables }
    $invalid = '[{"action":"install","artifact":"{missing}.exe"}]' | ConvertFrom-Json
    Assert-Fails { Invoke-BuildRecipe -Steps $invalid -ArtifactDirectory $scratch -Variables $variables }
    Write-Host 'All bootstrap helper checks passed.'
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
}

function fake-native {
    $script:nativeArguments = @($args)
    $global:LASTEXITCODE = $script:fakeExitCode
}
$script:fakeExitCode = 0
Invoke-BuildCommand fake-native @('path with spaces', '--locked')
if ($script:nativeArguments.Count -ne 2 -or $script:nativeArguments[0] -ne 'path with spaces') {
    throw 'Native command arguments were not preserved'
}
$script:fakeExitCode = 1
Assert-Fails { Invoke-BuildCommand fake-native @('build') }
$global:LASTEXITCODE = 0
Write-Host 'Native build command checks passed.'
