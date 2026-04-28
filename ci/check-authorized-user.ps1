Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$authorizedUsers = Get-Content ".github/relsre.json" | ConvertFrom-Json
$actor = $env:GITHUB_ACTOR

if (-not $actor) {
    throw "GITHUB_ACTOR is not set."
}

if ($authorizedUsers -contains $actor) {
    Write-Host "User $actor is authorized."
    exit 0
}

Write-Host "User $actor is unauthorized."
exit 1
