param (
    [string] $AdditionalUsersFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$authorizedUsers = Get-Content ".github/relsre.json" | ConvertFrom-Json
if ($AdditionalUsersFile) {
    $authorizedUsers = @($authorizedUsers) + @(Get-Content $AdditionalUsersFile | ConvertFrom-Json)
}
$actor = $env:GITHUB_ACTOR

if (-not $actor) {
    throw "GITHUB_ACTOR is not set."
}

if ($authorizedUsers -contains $actor -and
    (-not $env:GITHUB_TRIGGERING_ACTOR -or $authorizedUsers -contains $env:GITHUB_TRIGGERING_ACTOR)) {
    Write-Host "User $actor is authorized."
    exit 0
}

Write-Host "User $actor is unauthorized."
exit 1
