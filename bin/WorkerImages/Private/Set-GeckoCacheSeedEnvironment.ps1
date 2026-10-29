function Set-GeckoCacheSeedEnvironment($ImageConfig, $ImageKey) {
    if ($ImageConfig.experimental.gecko_cache_seed -ne $true) {
        # Workflow-level values apply to every matrix image.
        $env:PKR_VAR_gecko_hg_seed_revision = ''
        $env:PKR_VAR_gecko_git_seed_revision = ''
        $env:PKR_VAR_gecko_seed_decision = ''
        return
    }

    if ($ImageKey -notmatch '-alpha$') {
        throw "Gecko cache seeding is only supported for alpha configs: $ImageKey"
    }
    if (
        [string]::IsNullOrWhiteSpace($env:PKR_VAR_gecko_hg_seed_revision) -or
        [string]::IsNullOrWhiteSpace($env:PKR_VAR_gecko_git_seed_revision) -or
        [string]::IsNullOrWhiteSpace($env:PKR_VAR_gecko_seed_decision)
    ) {
        throw "Gecko cache seeding is enabled for $ImageKey, but seed inputs are missing"
    }
}
