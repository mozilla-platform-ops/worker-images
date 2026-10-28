# Shared by first boot, deploy-time bootstrap, and the WIM bake (Windows PowerShell 5.1).
function Install-VerifiedBootstrapInstaller {
    param (
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Destination,
        [Parameter(Mandatory)] [string] $Arguments
    )
    $ErrorActionPreference = 'Stop'
    $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'bootstrap-installers.json') -Raw | ConvertFrom-Json
    $entries = @($manifest.files | Where-Object { $_.name -eq $Name })
    if ($Name -notmatch '^[a-zA-Z0-9_-][a-zA-Z0-9_.-]*\.(exe|msi)$' -or
        $entries.Count -ne 1 -or $entries[0].sha256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw "Unknown installer or invalid SHA-256: $Name"
    }
    $entry = $entries[0]
    if (@($entry.urls).Count -eq 0 -or @($entry.urls | Where-Object { $_ -notmatch '^https://' }).Count) {
        throw "Invalid installer URLs: $Name"
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $path = Join-Path $Destination $Name
    $partial = "$path.partial"
    $downloaded = $false
    try {
        # Always replace cached installers with a verified download; existence is not trust.
        foreach ($url in $entry.urls) {
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                try {
                    Write-Host "Downloading $Name from $url (attempt $attempt/3)"
                    Invoke-WebRequest -Uri $url -OutFile $partial -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
                    $downloaded = $true
                    break
                } catch {
                    Write-Warning "Download failed for $Name from $url : $($_.Exception.Message)"
                    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
                    if ($attempt -lt 3) { Start-Sleep -Seconds 5 }
                }
            }
            if ($downloaded) { break }
        }
        if (-not $downloaded) { throw "All download attempts failed for $Name" }
        $actual = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash
        # A mismatch stops the install, including when the controlled mirror served it.
        if ($actual -ne $entry.sha256) {
            throw "SHA-256 mismatch for $Name from $url : expected $($entry.sha256), got $actual"
        }
        Move-Item -LiteralPath $partial -Destination $path -Force
        Write-Host "Verified $Name SHA-256 $actual"
        if ($Name -like '*.msi') {
            $process = Start-Process -FilePath msiexec.exe -ArgumentList "/i `"$path`" $Arguments" -Wait -PassThru -NoNewWindow
        } else {
            $process = Start-Process -FilePath $path -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
        }
        if ($process.ExitCode -notin @(0, 3010)) {
            throw "$Name install failed with exit code $($process.ExitCode)"
        }
    } finally {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    }
}
