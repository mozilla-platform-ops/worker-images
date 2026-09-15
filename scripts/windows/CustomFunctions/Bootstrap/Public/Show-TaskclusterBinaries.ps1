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
        # A binary that isn't installed yields an empty array here, whose .Name is $null -
        # drop those rather than emit a blank row into the markdown table.
    } | Where-Object { $PSItem.Name }
}