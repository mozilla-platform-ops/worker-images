function Set-YAMLModule {
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

    # Install from our mirror of the PSGallery package; PSGallery downloads fail in builds.
    $version = "0.4.12"
    $dest = "$env:ProgramFiles\WindowsPowerShell\Modules\powershell-yaml\$version"
    if (-not (Test-Path "$dest\powershell-yaml.psd1")) {
        $zip = Invoke-DownloadWithRetry -Url "https://roninpuppetassets.blob.core.windows.net/binaries/prerequisites/powershell-yaml.$version.nupkg" -Path "$env:TEMP\powershell-yaml.$version.zip"
        Expand-Archive -Path $zip -DestinationPath $dest -Force -ErrorAction Stop
    }
    Write-Log -message  ('{0} :: Installed Powershell-YAML' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'

    $stopwatch.Stop()
    $elapsedMinutes = [int][math]::Floor($stopwatch.Elapsed.TotalMinutes)
    $elapsedSeconds = $stopwatch.Elapsed.Seconds
    Write-Log -message ('{0} :: completed in {1} minutes, {2} seconds' -f $($MyInvocation.MyCommand.Name), $elapsedMinutes, $elapsedSeconds) -severity 'DEBUG'
    Write-Host "========== $($MyInvocation.MyCommand.Name) completed in $elapsedMinutes minutes, $elapsedSeconds seconds =========="
}
