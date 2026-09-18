# Shared helpers maintained by RelOps. Perf's recipe is windows-base.ps1.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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

function Invoke-BuildRecipe {
    param (
        [Parameter(Mandatory)] [object[]] $Steps,
        [Parameter(Mandatory)] [string] $ArtifactDirectory,
        [Parameter(Mandatory)] [object] $Variables
    )

    foreach ($step in $Steps) {
        if (-not $step.PSObject.Properties['action'] -or -not $step.PSObject.Properties['artifact']) {
            throw 'Each build step needs an action and artifact.'
        }
        $artifact = [string] $step.artifact
        foreach ($variable in $Variables.PSObject.Properties) {
            $artifact = $artifact.Replace("{$($variable.Name)}", [string] $variable.Value)
        }
        if ($artifact -match '\{[a-zA-Z0-9_]+\}') {
            throw "Unknown variable in artifact: $artifact"
        }
        if ([IO.Path]::GetFileName($artifact) -ne $artifact) {
            throw "Artifact must be a filename, not a path: $artifact"
        }
        $path = Join-Path $ArtifactDirectory $artifact
        switch ([string] $step.action) {
            'install' {
                $arguments = if ($step.PSObject.Properties['arguments']) { [string] $step.arguments } else { '' }
                foreach ($variable in $Variables.PSObject.Properties) {
                    $arguments = $arguments.Replace("{$($variable.Name)}", [string] $variable.Value)
                }
                if ($arguments -match '\{[a-zA-Z0-9_]+\}') {
                    throw "Unknown variable in arguments for ${artifact}: $arguments"
                }
                Install-BuildInstaller -Path $path -Arguments $arguments
            }
            'extract' {
                if (-not $step.PSObject.Properties['destination']) {
                    throw "Extract step for $artifact needs a destination."
                }
                Expand-BuildArchive -Path $path -Destination ([string] $step.destination)
            }
            default { throw "Unknown build action: $($step.action)" }
        }
    }
}

# PowerShell 5 does not turn native nonzero exit codes into terminating errors.
function Invoke-BuildCommand {
    param (
        [Parameter(Mandatory)] [string] $File,
        [string[]] $Arguments = @()
    )
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$File failed (exit $LASTEXITCODE)" }
}
