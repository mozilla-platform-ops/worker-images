$ErrorActionPreference = 'Stop'

$pages = gh api "repos/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID/jobs" --paginate --slurp
if ($LASTEXITCODE -ne 0) { throw 'Unable to query build job results.' }
$successful = @(
    foreach ($page in ($pages | ConvertFrom-Json)) {
        foreach ($job in $page.jobs) {
            if ($job.name -match '^Build (.+)$' -and $job.conclusion -eq 'success') {
                $Matches[1]
            }
        }
    }
)
$original = $env:ORIGINAL_OS_INT_MATRIX | ConvertFrom-Json
$matrices = @{
    os_integration = @($original.config | Where-Object { $_ -in $successful })
    wiz = @($successful | Where-Object { $_ -notmatch '^trusted-' })
}
foreach ($name in $matrices.Keys) {
    $configs = @($matrices[$name])
    $matrix = @{ config = $configs } | ConvertTo-Json -Compress
    "${name}_matrix=$matrix", "${name}_count=$($configs.Count)" >> $env:GITHUB_OUTPUT
}
