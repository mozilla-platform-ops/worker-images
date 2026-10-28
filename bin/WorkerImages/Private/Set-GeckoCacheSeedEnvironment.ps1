function Set-GeckoCacheSeedEnvironment {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $ImageConfig,
        [Parameter(Mandatory)]
        [String] $ImageKey
    )

    $enabled = $false
    $experimental = $ImageConfig['experimental']
    if (
        $experimental -is [System.Collections.IDictionary] -and
        $experimental.Contains('gecko_cache_seed')
    ) {
        $enabled = $experimental['gecko_cache_seed']
        if ($enabled -isnot [bool]) {
            throw 'experimental.gecko_cache_seed must be a YAML boolean'
        }
    }

    if (-not $enabled) {
        # Workflow-level values apply to every matrix image, so clear them for opt-out configs.
        $env:PKR_VAR_gecko_hg_seed_revision = ''
        $env:PKR_VAR_gecko_git_seed_revision = ''
        $env:PKR_VAR_gecko_seed_decision = ''
        Write-Host "Gecko cache seed disabled for $ImageKey"
        return
    }

    if ($ImageKey -notmatch '-alpha$') {
        throw "experimental.gecko_cache_seed is only supported for alpha configs: $ImageKey"
    }

    $requiredVariables = @(
        'PKR_VAR_gecko_hg_seed_revision',
        'PKR_VAR_gecko_git_seed_revision',
        'PKR_VAR_gecko_seed_decision'
    )
    foreach ($name in $requiredVariables) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            throw "Gecko cache seeding is enabled for $ImageKey, but $name is empty"
        }
    }

    Write-Host "Gecko cache seed enabled for $ImageKey"
}
