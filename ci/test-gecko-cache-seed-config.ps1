$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../bin/WorkerImages/Private/Set-GeckoCacheSeedEnvironment.ps1"

$seedVariables = @(
    'PKR_VAR_gecko_hg_seed_revision',
    'PKR_VAR_gecko_git_seed_revision',
    'PKR_VAR_gecko_seed_decision'
)

function Assert-Throws {
    param (
        [scriptblock] $Action,
        [string] $Message
    )

    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -like "*$Message*") {
            return
        }
        throw
    }

    throw "Expected error containing: $Message"
}

foreach ($name in $seedVariables) {
    [Environment]::SetEnvironmentVariable($name, 'stale-value')
}
Set-GeckoCacheSeedEnvironment -ImageConfig @{} -ImageKey 'win11-64-24h2-alpha'
foreach ($name in $seedVariables) {
    if ([Environment]::GetEnvironmentVariable($name) -ne '') {
        throw "$name was not cleared when the feature flag was absent"
    }
}

$config = @{ experimental = @{ gecko_cache_seed = $true } }
$values = @{
    PKR_VAR_gecko_hg_seed_revision = 'a' * 40
    PKR_VAR_gecko_git_seed_revision = 'b' * 40
    PKR_VAR_gecko_seed_decision = 'c' * 22
}
foreach ($name in $seedVariables) {
    [Environment]::SetEnvironmentVariable($name, $values[$name])
}
Set-GeckoCacheSeedEnvironment -ImageConfig $config -ImageKey 'win11-64-24h2-alpha'

[Environment]::SetEnvironmentVariable('PKR_VAR_gecko_seed_decision', '')
Assert-Throws {
    Set-GeckoCacheSeedEnvironment -ImageConfig $config -ImageKey 'win11-64-24h2-alpha'
} 'PKR_VAR_gecko_seed_decision is empty'

Assert-Throws {
    Set-GeckoCacheSeedEnvironment -ImageConfig $config -ImageKey 'win11-64-24h2'
} 'only supported for alpha configs'

Assert-Throws {
    Set-GeckoCacheSeedEnvironment -ImageConfig @{ experimental = @{ gecko_cache_seed = 'true' } } -ImageKey 'win11-64-24h2-alpha'
} 'must be a YAML boolean'

Write-Host 'Gecko cache seed config checks passed'
