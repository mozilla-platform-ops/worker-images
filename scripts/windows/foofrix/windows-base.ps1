# FooFrix image recipe: edit the installation steps below.
# Guide and copy/paste examples: config/foofrix/README.md
# This runs once while building the image, as Windows SYSTEM (not the VM user).
# Use machine-wide installers and C:\FooFrix paths, not user-profile directories.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/bootstrap-helpers.ps1"

# 1. Base tools. Add one Install-BuildPackage line for each Chocolatey package.
Install-BuildPackage -Name 'git'
Install-BuildPackage -Name 'nodejs' -Version '24.13.0'
Install-BuildPackage -Name 'python' -Version '3.13.12'

# Native build prerequisites; these are shared by Rust tools and browser builds.
Install-BuildPackage -Name 'visualstudio2022-workload-vctools' -PackageParameters '--includeRecommended'
Install-BuildPackage -Name '7zip'

# Rust must survive image generalization and be visible outside SYSTEM's profile.
foreach ($directory in @('C:\FooFrix\cargo', 'C:\FooFrix\rustup', 'C:\FooFrix\src', 'C:\FooFrix\tools')) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
$env:CARGO_HOME = 'C:\FooFrix\cargo'
$env:RUSTUP_HOME = 'C:\FooFrix\rustup'
[Environment]::SetEnvironmentVariable('CARGO_HOME', $env:CARGO_HOME, 'Machine')
[Environment]::SetEnvironmentVariable('RUSTUP_HOME', $env:RUSTUP_HOME, 'Machine')
Invoke-WebRequest 'https://win.rustup.rs/x86_64' -OutFile "$env:TEMP\rustup-init.exe" -UseBasicParsing
Install-BuildInstaller -Path "$env:TEMP\rustup-init.exe" -Arguments '-y --no-modify-path --profile minimal --default-toolchain stable'

# Google documents /allusers for unattended machine-wide installation.
Invoke-WebRequest 'https://dl.google.com/dl/cloudsdk/channels/rapid/GoogleCloudSDKInstaller.exe' -OutFile "$env:TEMP\GoogleCloudSDKInstaller.exe" -UseBasicParsing
Install-BuildInstaller -Path "$env:TEMP\GoogleCloudSDKInstaller.exe" -Arguments '/S /allusers /noreporting /nostartmenu /nodesktop /D=C:\FooFrix\tools\google-cloud-sdk'
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
[Environment]::SetEnvironmentVariable('Path', "$machinePath;C:\FooFrix\cargo\bin;C:\FooFrix\tools\google-cloud-sdk\google-cloud-sdk\bin", 'Machine')

# 2. Resources uploaded to the private artifacts container are already local.
# Keep this path aligned with the artifact_prefix selected when starting the build.
# Example: blob windows/releases/example/chromium.zip arrives at
# C:\FooFrix\artifacts\windows\releases\example\chromium.zip.
# Uncomment and replace these examples when the actual artifacts are available:
# $release = 'C:\FooFrix\artifacts\windows\releases\example'
# Expand-BuildArchive -Path "$release\chromium.zip" -Destination 'C:\FooFrix\chromium'
# Expand-BuildArchive -Path "$release\firefox-source.zip" -Destination 'C:\FooFrix\src'
# Install-BuildInstaller -Path "$release\tools.msi"
# Install-BuildInstaller -Path "$release\setup.exe" -Arguments '/quiet /norestart'

# 3. Add a matching check in tests/win/foofrix-base.tests.ps1 for new tools.
# Packer restarts Windows after this script, then runs those checks before publishing.
# Do not log in, fetch API keys, start FooFrix, or reboot from this recipe.
