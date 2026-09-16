# FooFrix image recipe: edit the installation steps below.
# Guide and copy/paste examples: config/foofrix/README.md
# This runs once while building the image, as Windows SYSTEM (not the VM user).
# Use machine-wide installers and C:\FooFrix paths, not user-profile directories.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/bootstrap-helpers.ps1"
$software = (Get-Content 'C:\FooFrix\image-config.json' -Raw | ConvertFrom-Json).software

# Actions downloads these from Azure and checks config/foofrix/installers.json.
$installers = 'C:\FooFrix\artifacts\installers'
Install-BuildInstaller -Path "$installers\Git-$($software.git)-64-bit.exe" -Arguments '/VERYSILENT /NORESTART /ALLUSERS /SP- /o:PathOption=Cmd'
Install-BuildInstaller -Path "$installers\node-v$($software.node)-x64.msi" -Arguments 'ALLUSERS=1'
Install-BuildInstaller -Path "$installers\python-$($software.python)-amd64.exe" -Arguments '/quiet InstallAllUsers=1 PrependPath=1 Include_test=0 Include_launcher=0 TargetDir=C:\FooFrix\Python'

# Native build prerequisites; these are shared by Rust tools and browser builds.
# The staged C++ bootstrapper still downloads its components from Microsoft.
Install-BuildInstaller -Path "$installers\$($software.visual_studio_installer)" -Arguments '--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
Install-BuildInstaller -Path "$installers\7z$($software.seven_zip.Replace('.', ''))-x64.exe" -Arguments '/S'

# Rust must survive image generalization and be visible outside SYSTEM's profile.
foreach ($directory in @('C:\FooFrix\cargo', 'C:\FooFrix\rustup', 'C:\FooFrix\src', 'C:\FooFrix\tools')) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
$env:CARGO_HOME = 'C:\FooFrix\cargo'
$env:RUSTUP_HOME = 'C:\FooFrix\rustup'
[Environment]::SetEnvironmentVariable('CARGO_HOME', $env:CARGO_HOME, 'Machine')
[Environment]::SetEnvironmentVariable('RUSTUP_HOME', $env:RUSTUP_HOME, 'Machine')
# rustup's initial EXE is staged; it downloads this pinned toolchain from Rust.
Install-BuildInstaller -Path "$installers\$($software.rustup_installer)" -Arguments "-y --no-modify-path --profile minimal --default-toolchain $($software.rust)"

# The versioned ZIP includes Python and needs no online installer or login.
Expand-BuildArchive -Path "$installers\google-cloud-sdk-$($software.google_cloud_cli)-windows-x86_64-bundled-python.zip" -Destination 'C:\FooFrix\tools'
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
[Environment]::SetEnvironmentVariable('Path', "$machinePath;C:\FooFrix\cargo\bin;C:\FooFrix\tools\google-cloud-sdk\bin", 'Machine')

# Add a matching check in tests/win/foofrix-base.tests.ps1 for new tools.
# Packer restarts Windows after this script, then runs those checks before publishing.
# Do not log in, fetch API keys, start FooFrix, or reboot from this recipe.

# MozillaBuild supplies the Windows Firefox build shell and native Python.
Install-BuildInstaller -Path "$installers\MozillaBuildSetup-$($software.mozillabuild).exe" -Arguments '/S'
Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1
