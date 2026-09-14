# Shared helpers maintained by RelOps. Perf's recipe is windows-base.ps1.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Install-BuildPackage {
    param (
        [Parameter(Mandatory)] [string] $Name,
        [string] $Version
    )

    if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
        Invoke-RestMethod 'https://community.chocolatey.org/install.ps1' | Invoke-Expression
    }
    Write-Host "Installing package: $Name $Version"
    $arguments = @('install', '--yes', '--no-progress', '--use-package-exit-codes', $Name)
    if ($Version) { $arguments += @('--version', $Version) }
    & choco.exe @arguments
    # 3010 requests a reboot; Packer performs it after the recipe completes.
    if ($LASTEXITCODE -notin @(0, 3010)) {
        throw "Package $Name failed (exit $LASTEXITCODE). See Chocolatey output above."
    }
}

function Install-BuildInstaller {
    param (
        [Parameter(Mandatory)] [string] $Path,
        # EXE silent switches vary by vendor. MSI silent switches are automatic.
        [string] $Arguments = ''
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Installer not found: $Path. Check the artifact prefix and blob path."
    }
    Write-Host "Installing artifact: $Path"
    if ([IO.Path]::GetExtension($Path) -ieq '.msi') {
        $Arguments = "/i `"$Path`" /qn /norestart $Arguments"
        $Path = 'msiexec.exe'
    } elseif ([IO.Path]::GetExtension($Path) -ine '.exe') {
        throw 'Installer must be an MSI or EXE file.'
    }
    $options = @{ FilePath = $Path; Wait = $true; PassThru = $true; NoNewWindow = $true }
    if ($Arguments) { $options.ArgumentList = $Arguments }
    $process = Start-Process @options
    if ($process.ExitCode -notin @(0, 3010)) {
        throw "Installer $Path failed (exit $($process.ExitCode)). Check its silent-install options."
    }
}

function Expand-BuildArchive {
    param (
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Destination
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Archive not found: $Path. Check the artifact prefix and blob path."
    }
    Write-Host "Extracting $Path to $Destination"
    Expand-Archive -LiteralPath $Path -DestinationPath $Destination -Force
}
