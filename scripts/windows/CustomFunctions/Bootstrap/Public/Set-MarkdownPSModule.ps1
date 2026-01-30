function Set-MarkdownPSModule {
    [CmdletBinding()]
    param (

    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Log -message ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    Write-Host "========== $($MyInvocation.MyCommand.Name) started at $((Get-Date).ToUniversalTime().ToString('o')) =========="
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    ## Bootstrap for powershell modules
    Get-PackageProvider -Name Nuget -ForceBootstrap | Out-Null
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

    ## install MarkdownPS
    Install-Module -Name "MarkdownPS" -Force
    Write-Log -message  ('{0} :: Installed MarkdownPS' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'

    $stopwatch.Stop()
    Write-Log -message ('{0} :: completed in {1} minutes, {2} seconds' -f $($MyInvocation.MyCommand.Name), $stopwatch.Elapsed.Minutes, $stopwatch.Elapsed.Seconds) -severity 'DEBUG'
    Write-Host "========== $($MyInvocation.MyCommand.Name) completed in $($stopwatch.Elapsed.Minutes) minutes, $($stopwatch.Elapsed.Seconds) seconds =========="
}
