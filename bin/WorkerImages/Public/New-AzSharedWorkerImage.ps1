function New-AzSharedWorkerImage {
    [CmdletBinding()]
    param (
        [String] $github_token,
        [ValidatePattern('^(trusted-)?win[a-z0-9-]+$')]
        [String] $Key,
        [String] $Client_ID,
        [String] $Application_ID,
        [String] $oidc_request_url,
        [String] $oidc_request_token,
        [String] $Subscription_ID,
        [String] $Tenant_ID,
        [switch] $DeferReplication
    )

    $ErrorActionPreference = 'Stop'
    if (-not (Test-Path -LiteralPath "config/$Key.yaml" -PathType Leaf)) {
        throw "Unknown Windows image config: $Key"
    }
    Import-WorkerImagesYaml
    $DefaultYaml = ConvertFrom-Yaml (Get-Content 'config/windows_production_defaults.yaml' -Raw)
    $ImageYaml = ConvertFrom-Yaml (Get-Content "config/$Key.yaml" -Raw)
    $Y = Merge-ImageDefaults -Defaults $DefaultYaml -Image $ImageYaml

    $ENV:PKR_VAR_config = $Key
    $ENV:PKR_VAR_image_publisher = $Y.image['publisher']
    $ENV:PKR_VAR_image_offer = $Y.image['offer']
    $ENV:PKR_VAR_image_sku = $Y.image['sku']
    $ENV:PKR_VAR_image_version = $Y.image['version']
    $ENV:PKR_VAR_resource_group = $Y.azure['managed_image_resource_group_name']
    $ENV:PKR_VAR_vm_size = $Y.vm['size']
    $ENV:PKR_VAR_use_spot = ($Y.vm['spot'] -eq $true).ToString().ToLowerInvariant()
    $ENV:PKR_VAR_build_location = $Y.azure['build_location']
    if (-not $ENV:PKR_VAR_build_location) { $ENV:PKR_VAR_build_location = 'centralus' }
    $ENV:PKR_VAR_base_image = $Y.vm.tags['base_image']
    $ENV:PKR_VAR_source_branch = $Y.vm.tags['sourceBranch']
    $ENV:PKR_VAR_source_repository = $Y.vm.tags['sourceRepository']
    $ENV:PKR_VAR_source_organization = $Y.vm.tags['sourceOrganization']
    $ENV:PKR_VAR_deployment_id = $Y.vm.tags['deploymentId']
    $ENV:PKR_VAR_worker_pool_id = $Y.vm.tags['worker_pool_id']
    $ENV:PKR_VAR_gallery_name = $Y.sharedimage['gallery_name']
    $ENV:PKR_VAR_image_name = $Y.sharedimage['image_name']
    $ENV:PKR_VAR_sharedimage_version = $Y.sharedimage['image_version']
    $ENV:PKR_VAR_git_version = $Y.vm['git_version']
    $ENV:PKR_VAR_openvox_version = $Y.vm['openvox_version']
    foreach ($version in @($ENV:PKR_VAR_git_version, $ENV:PKR_VAR_openvox_version)) {
        if ($version -notmatch '^\d+(\.\d+)+$') { throw "Invalid prerequisite version: $version" }
    }

    $ENV:PKR_VAR_client_id = $Client_ID
    $ENV:PKR_VAR_application_id = $Application_ID
    $ENV:PKR_VAR_tenant_id = $Tenant_ID
    $ENV:PKR_VAR_subscription_id = $Subscription_ID
    $ENV:PKR_VAR_oidc_request_url = $oidc_request_url
    $ENV:PKR_VAR_oidc_request_token = $oidc_request_token
    # An explicit empty list means build-region only, not the HCL fallback.
    if (-not $Y.azure.ContainsKey('locations')) { throw 'azure.locations must explicitly list replica targets (or [] for build-region only).' }
    $targetRegions = @($Y.azure['locations']) + @($ENV:PKR_VAR_build_location)
    $targetRegions = @($targetRegions | Where-Object { $_ } | Sort-Object -Unique)
    $ENV:PKR_VAR_replication_regions = ConvertTo-Json -InputObject $targetRegions -Compress
    $shallow = $Y.azure['shallow_replication'] -eq $true
    $ENV:PKR_VAR_use_shallow_replication = $shallow.ToString().ToLowerInvariant()
    if ($shallow) {
        if ($Key -notlike '*-alpha' -or $DeferReplication -or $targetRegions.Count -ne 1) {
            throw 'Shallow replication requires a single-region alpha config in its build region.'
        }
    }
    if ($DeferReplication) {
        if ($Key -like '*-alpha' -or $targetRegions.Count -lt 1) {
            throw 'Deferred replication requires a production config with explicit target regions.'
        }
        $ENV:PKR_VAR_replication_regions = ConvertTo-Json -InputObject @($ENV:PKR_VAR_build_location) -Compress
    }
    $ENV:PKR_VAR_temp_resource_group_name = '{0}-{1}-{2}-pkrtmp' -f `
        $ENV:PKR_VAR_worker_pool_id, $ENV:PKR_VAR_deployment_id, ([guid]::NewGuid().ToString('N').Substring(0, 8))

    Assert-AzVmSkuAvailable -SubscriptionId $Subscription_ID -Location $ENV:PKR_VAR_build_location `
        -VmSize $ENV:PKR_VAR_vm_size -UseSpot ($Y.vm['spot'] -eq $true)

    # Compress on the runner; keep the Bootstrap directory itself inside the archive.
    $staging = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $staging
    try {
        Compress-Archive -Path 'scripts/windows/CustomFunctions/Bootstrap' -DestinationPath "$staging/Bootstrap.zip"
        Compress-Archive -Path 'tests/win/*' -DestinationPath "$staging/tests.zip"
        $ENV:PKR_VAR_bootstrap_archive = "$staging/Bootstrap.zip"
        $ENV:PKR_VAR_tests_archive = "$staging/tests.zip"
        $ENV:PACKER_GITHUB_API_TOKEN = $github_token
        $ENV:PKR_VAR_use_keyvault = ($Key -like 'trusted-*').ToString().ToLowerInvariant()
        $ENV:PKR_VAR_vault_name = if ($Key -like 'trusted-*') { 'kv-central-us-cot' } else { 'kv-central-us-key' }
        packer init azure.pkr.hcl
        if ($LASTEXITCODE -ne 0) { throw "packer init failed: $LASTEXITCODE" }
        $buildArgs = @('build', '--only', 'azure-arm.sig')
        if ($Key -like '*-alpha') { $buildArgs += '-force' }
        & packer @buildArgs azure.pkr.hcl
        if ($LASTEXITCODE -ne 0) { throw "packer build failed: $LASTEXITCODE" }
        if ($DeferReplication) {
            @{
                image_id = "/subscriptions/$Subscription_ID/resourceGroups/$($Y.azure['managed_image_resource_group_name'])/providers/Microsoft.Compute/galleries/$($Y.sharedimage['gallery_name'])/images/$($Y.sharedimage['image_name'])/versions/$($Y.sharedimage['image_version'])"
                regions = $targetRegions
                config = $Key
                commit = $env:GITHUB_SHA
                run_id = $env:GITHUB_RUN_ID
            } | ConvertTo-Json | Set-Content "$Key-replication.json" -Encoding utf8
        }
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
}
