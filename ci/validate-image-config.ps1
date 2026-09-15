param (
    [ValidateSet('azure', 'azure-trusted', 'gcp', 'tceng', 'all')]
    [string] $Family = 'all'
)

$ErrorActionPreference = 'Stop'
$patterns = @{
    azure = '^win[a-z0-9-]+$'
    'azure-trusted' = '^trusted-win[a-z0-9-]+$'
    gcp = '^(trusted-)?gw-fxci-gcp-[a-z0-9-]+-alpha$'
    tceng = '^[a-zA-Z0-9_-]+$'
    all = '^(trusted-)?(win|gw-fxci-gcp-)[a-z0-9-]+$'
}
$directory = if ($Family -eq 'tceng') { 'config/tceng' } else { 'config' }
if ($env:CONFIG -notmatch $patterns[$Family] -or
    -not (Test-Path -LiteralPath "$directory/$($env:CONFIG).yaml" -PathType Leaf)) {
    throw "Unknown $Family image config: $($env:CONFIG). Choose a YAML basename from $directory."
}
