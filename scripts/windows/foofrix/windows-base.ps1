# FooFrix image setup around the data-driven build_steps recipe.
# Guide and copy/paste examples: config/foofrix/README.md
# This runs once while building the image, as Windows SYSTEM (not the VM user).
# Use machine-wide installers and C:\FooFrix paths, not user-profile directories.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/bootstrap-helpers.ps1"

# Rust must survive image generalization and be visible outside SYSTEM's profile.
foreach ($directory in @('C:\FooFrix\cargo', 'C:\FooFrix\rustup', 'C:\FooFrix\src', 'C:\FooFrix\tools')) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
$env:CARGO_HOME = 'C:\FooFrix\cargo'
$env:RUSTUP_HOME = 'C:\FooFrix\rustup'
[Environment]::SetEnvironmentVariable('CARGO_HOME', $env:CARGO_HOME, 'Machine')
[Environment]::SetEnvironmentVariable('RUSTUP_HOME', $env:RUSTUP_HOME, 'Machine')

# download-installers.ps1 verifies these before the YAML recipe runs.
$config = Get-Content 'C:\FooFrix\image-config.json' -Raw | ConvertFrom-Json
Invoke-BuildRecipe -Steps $config.build_steps -ArtifactDirectory 'C:\FooFrix\artifacts\installers' -Variables $config.software

$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
[Environment]::SetEnvironmentVariable('Path', "$machinePath;C:\FooFrix\cargo\bin;C:\FooFrix\tools\google-cloud-sdk\bin", 'Machine')

# Add a matching check in tests/win/foofrix-base.tests.ps1 for new tools.
# Packer restarts Windows after this script, then runs those checks before publishing.
# Do not log in, fetch API keys, start FooFrix, or reboot from this recipe.

Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1
