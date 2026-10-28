$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../bin/WorkerImages/Private/Set-GeckoCacheSeedEnvironment.ps1"

$variables = @(
    'PKR_VAR_gecko_hg_seed_revision',
    'PKR_VAR_gecko_git_seed_revision',
    'PKR_VAR_gecko_seed_decision'
)

function Assert-Throws($Action, $Message) {
    try { & $Action }
    catch { if ($_.Exception.Message -like "*$Message*") { return }; throw }
    throw "Expected error containing: $Message"
}

foreach ($name in $variables) { [Environment]::SetEnvironmentVariable($name, 'stale') }
Set-GeckoCacheSeedEnvironment @{} 'win11-64-24h2-alpha'
if ($variables | Where-Object { [Environment]::GetEnvironmentVariable($_) }) {
    throw 'Seed inputs were not cleared when the flag was absent'
}

$config = @{ experimental = @{ gecko_cache_seed = $true } }
$values = @{
    PKR_VAR_gecko_hg_seed_revision = 'a' * 40
    PKR_VAR_gecko_git_seed_revision = 'b' * 40
    PKR_VAR_gecko_seed_decision = 'c' * 22
}
foreach ($name in $variables) { [Environment]::SetEnvironmentVariable($name, $values[$name]) }
Set-GeckoCacheSeedEnvironment $config 'win11-64-24h2-alpha'
if ($variables | Where-Object { [Environment]::GetEnvironmentVariable($_) -ne $values[$_] }) {
    throw 'Seed inputs were not preserved when the flag was enabled'
}

[Environment]::SetEnvironmentVariable('PKR_VAR_gecko_seed_decision', '')
Assert-Throws { Set-GeckoCacheSeedEnvironment $config 'win11-64-24h2-alpha' } 'seed inputs are missing'
Assert-Throws { Set-GeckoCacheSeedEnvironment $config 'win11-64-24h2' } 'only supported for alpha configs'

Write-Host 'Gecko cache seed config checks passed'
