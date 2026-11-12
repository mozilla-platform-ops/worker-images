function Test-WorkerImagesUserAuthorization {
    <#
    .SYNOPSIS
    Checks whether the GitHub actor and triggering actor are authorized.

    .PARAMETER AdditionalUsersFile
    Optional JSON file with additional authorized usernames.

    .PARAMETER Actor
    Actor to check. Defaults to GITHUB_ACTOR.

    .PARAMETER TriggeringActor
    Triggering actor to check. Defaults to GITHUB_TRIGGERING_ACTOR.

    .OUTPUTS
    System.Boolean
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [string] $AdditionalUsersFile,

        [Parameter()]
        [string] $Actor = $env:GITHUB_ACTOR,

        [Parameter()]
        [string] $TriggeringActor = $env:GITHUB_TRIGGERING_ACTOR
    )

    if ([string]::IsNullOrWhiteSpace($Actor)) {
        throw 'GITHUB_ACTOR is not set.'
    }

    $repositoryRoot = [IO.Path]::GetFullPath((Get-Location).Path)
    $authorizedUsersPath = Join-Path $repositoryRoot '.github/relops.json'
    if (-not (Test-Path -LiteralPath $authorizedUsersPath -PathType Leaf)) {
        throw "Authorized users file not found: $authorizedUsersPath"
    }

    $authorizedUsers = @(
        Get-Content -LiteralPath $authorizedUsersPath -Raw -ErrorAction Stop | ConvertFrom-Json
    )

    if (-not [string]::IsNullOrWhiteSpace($AdditionalUsersFile)) {
        $additionalUsersPath = if ([IO.Path]::IsPathRooted($AdditionalUsersFile)) {
            $AdditionalUsersFile
        } else {
            Join-Path $repositoryRoot $AdditionalUsersFile
        }
        if (-not (Test-Path -LiteralPath $additionalUsersPath -PathType Leaf)) {
            throw "Additional authorized users file not found: $additionalUsersPath"
        }
        $authorizedUsers += @(
            Get-Content -LiteralPath $additionalUsersPath -Raw -ErrorAction Stop | ConvertFrom-Json
        )
    }

    return [bool](
        ($authorizedUsers -contains $Actor) -and
        ([string]::IsNullOrWhiteSpace($TriggeringActor) -or $authorizedUsers -contains $TriggeringActor)
    )
}
