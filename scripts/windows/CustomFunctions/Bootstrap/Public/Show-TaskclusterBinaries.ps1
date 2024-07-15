function Show-TaskclusterBinaries {
    [CmdletBinding()]
    param (
        
    )
    
    @(Get-GenericWorkerVersion),
    @(Get-LiveLogVersion),
    @(Get-WorkerRunnerVersion),
    @(Get-ProxyVersion) | ForEach-Object {
        [PSCustomObject]@{
            Name = $PSItem.Name
            Version = $PSItem.Version
        }
    }
}