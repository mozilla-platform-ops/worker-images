[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Branch,
    [Parameter(Mandatory)][string] $Key,
    [Parameter(Mandatory)][ValidateSet('Azure', 'GCP')][string] $Provider
)
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
    throw 'GITHUB_OUTPUT is not set.'
}

# Run from the trusted main checkout, before the workflow checks out branch code.
Import-Module "$PSScriptRoot/../bin/WorkerImages/WorkerImages.psm1" -Force
$result = Resolve-WorkerImageDevelopmentBuild @PSBoundParameters
"revision=$($result.Revision)", "notes=$($result.Notes)" | Add-Content -LiteralPath $env:GITHUB_OUTPUT
Write-Information "Development build: $Branch at $($result.Revision) ($Key, $Provider)" -InformationAction Continue
