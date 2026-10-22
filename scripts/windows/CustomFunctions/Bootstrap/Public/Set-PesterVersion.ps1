function Set-PesterVersion {
    [CmdletBinding()]
    param (

    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Log -message ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    Write-Host "========== $($MyInvocation.MyCommand.Name) started at $((Get-Date).ToUniversalTime().ToString('o')) =========="
    trap {
        $stopwatch.Stop()
        $elapsedMinutes = [int][math]::Floor($stopwatch.Elapsed.TotalMinutes)
        $elapsedSeconds = $stopwatch.Elapsed.Seconds
        Write-Log -message ('{0} :: completed in {1} minutes, {2} seconds' -f $($MyInvocation.MyCommand.Name), $elapsedMinutes, $elapsedSeconds) -severity 'DEBUG'
        Write-Host "========== $($MyInvocation.MyCommand.Name) completed in $elapsedMinutes minutes, $elapsedSeconds seconds =========="
        throw $_
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    ## Bootstrap for powershell modules
    Get-PackageProvider -Name Nuget -ForceBootstrap | Out-Null
    Initialize-PSGallery

    Foreach ($module in @("C:\Program Files (x86)\WindowsPowerShell\Modules\Pester", "C:\Program Files\WindowsPowerShell\Modules\Pester")) {
        takeown /F $module /A /R | Out-Null
        icacls $module /reset | Out-Null
        icacls $module /grant "*S-1-5-32-544:F" /inheritance:d /T | Out-Null
        Remove-Item -Path $module -Recurse -Force -Confirm:$false | Out-Null
    }

    ## Install Pester. Gallery downloads occasionally fail transiently, so
    ## retry instead of continuing without a test framework.
    $installed = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Install-Module -Name Pester -Force -ErrorAction Stop
            $installed = $true
            break
        }
        catch {
            Write-Warning "Pester install attempt $attempt failed: $($_.Exception.Message)"
            if ($attempt -lt 3) { Start-Sleep -Seconds 15 }
        }
    }
    if (-not $installed) {
        throw 'Failed to install Pester after 3 attempts'
    }

    $pester = Get-Module -ListAvailable -Name Pester |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $pester -or $pester.Version.Major -lt 5) {
        throw "Pester 5 or later is required; found version '$($pester.Version)'"
    }

    Write-Log -message  ('{0} :: Pester {1} installation appears complete' -f $($MyInvocation.MyCommand.Name), $pester.Version) -severity 'DEBUG'

    $stopwatch.Stop()
    $elapsedMinutes = [int][math]::Floor($stopwatch.Elapsed.TotalMinutes)
    $elapsedSeconds = $stopwatch.Elapsed.Seconds
    Write-Log -message ('{0} :: completed in {1} minutes, {2} seconds' -f $($MyInvocation.MyCommand.Name), $elapsedMinutes, $elapsedSeconds) -severity 'DEBUG'
    Write-Host "========== $($MyInvocation.MyCommand.Name) completed in $elapsedMinutes minutes, $elapsedSeconds seconds =========="
}
