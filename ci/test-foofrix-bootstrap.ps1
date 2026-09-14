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
function choco.exe {
    $script:packageArguments = @($args)
    $global:LASTEXITCODE = $script:fakeExitCode
}
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
    $script:fakeExitCode = 0
    Install-BuildPackage -Name 'nodejs' -Version '24.13.0'
    if (($script:packageArguments -join ' ') -ne 'install --yes --no-progress --use-package-exit-codes nodejs --version 24.13.0') {
        throw 'Package arguments were not preserved'
    }
    $script:fakeExitCode = 3010
    Install-BuildPackage -Name 'git'
    $script:fakeExitCode = 1
    Assert-Fails { Install-BuildPackage -Name 'git' }
    $script:fakeExitCode = 1641
    Assert-Fails { Install-BuildPackage -Name 'git' }

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
    Write-Host 'All bootstrap helper checks passed.'
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
