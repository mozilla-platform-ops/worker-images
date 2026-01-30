function Disable-Services {
    [CmdletBinding()]
    param (
        [String[]]$Services = @("wuauserv", "usosvc")
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Log -message ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    Write-Host "========== $($MyInvocation.MyCommand.Name) started at $((Get-Date).ToUniversalTime().ToString('o')) =========="

    foreach ($service in $Services) {
        ## check if it even exists
        $exists = Get-Service $service -ErrorAction SilentlyContinue
        ## If it does exist, then do something
        if (-Not [string]::IsNullOrEmpty($exists)) {
            ## If not disabled, stop and disable it
            if ((Get-Service $service).StartType -ne 'Disabled') {
                if ((Get-Service $service).Status -ne 'Stopped') {
                    Stop-Service $service -Force
                }
                Get-Service $service | Set-Service -StartupType Disabled
            }
        }
    }

    $stopwatch.Stop()
    Write-Log -message ('{0} :: completed in {1} minutes, {2} seconds' -f $($MyInvocation.MyCommand.Name), $stopwatch.Elapsed.Minutes, $stopwatch.Elapsed.Seconds) -severity 'DEBUG'
    Write-Host "========== $($MyInvocation.MyCommand.Name) completed in $($stopwatch.Elapsed.Minutes) minutes, $($stopwatch.Elapsed.Seconds) seconds =========="
}