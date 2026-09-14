# FooFrix owns this standalone image's software. No Taskcluster services are installed.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
    Invoke-RestMethod 'https://community.chocolatey.org/install.ps1' | Invoke-Expression
}

# Match the Node major used by FooFrix. Versions mirror the TCEng base tooling.
$packages = @(
    @{ Name = 'git'; Version = $null },
    @{ Name = 'nodejs'; Version = '24.13.0' },
    @{ Name = 'python'; Version = '3.13.12' }
)
foreach ($package in $packages) {
    $arguments = @('install', '--yes', '--no-progress', $package.Name)
    if ($package.Version) { $arguments += @('--version', $package.Version) }
    & choco.exe @arguments
    if ($LASTEXITCODE -notin @(0, 1641, 3010)) {
        throw "Installation of $($package.Name) failed: $LASTEXITCODE"
    }
}

# Artifacts are available for Perf's image-specific installation steps here.
# Add reviewed installation commands to this script; do not execute arbitrary blobs.
Write-Host 'FooFrix artifacts: C:\FooFrix\artifacts'
