function Disable-Services {
    [CmdletBinding()]
    param (
        [String[]]$Services = @("wuauserv", "usosvc")
    )

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
}