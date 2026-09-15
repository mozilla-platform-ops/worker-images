function Set-AzSharedWorkerImageVariables {
    [CmdletBinding()]
    param (
        [String] $github_token,
        [String] $Key,
        [String] $Client_ID,
        [String] $Application_ID,
        [String] $oidc_request_url,
        [String] $oidc_request_token,
        [String] $Subscription_ID,
        [String] $Tenant_ID
    )

    Import-WorkerImagesYaml

    $DefaultYaml = ConvertFrom-Yaml (Get-Content "config/windows_production_defaults.yaml" -Raw)
    $ImageYaml   = ConvertFrom-Yaml (Get-Content "config/$Key.yaml" -Raw)

    $Y = Merge-ImageDefaults $DefaultYaml $ImageYaml

    # Set environment variables
    $ENV:PKR_VAR_config = $Key
    $ENV:PKR_VAR_image_key_name = $Key
    $ENV:PKR_VAR_image_publisher = $Y.image["publisher"]
    $ENV:PKR_VAR_image_offer = $Y.image["offer"]
    $ENV:PKR_VAR_image_sku = $Y.image["sku"]
    $ENV:PKR_VAR_image_version = $Y.image["version"]
    $ENV:PKR_VAR_resource_group = $Y.azure["managed_image_resource_group_name"]
    $ENV:PKR_VAR_vm_size = $Y.vm["size"]
    $ENV:PKR_VAR_use_spot = ($Y.vm["spot"] -eq $true).ToString().ToLowerInvariant()
    $BuildLocation = $Y.azure["build_location"]
    if ([string]::IsNullOrWhiteSpace($BuildLocation)) {
        $BuildLocation = "Central US"
        Write-Host "WARNING: No build_location specified in config, defaulting to '$BuildLocation'"
    }
    $ENV:PKR_VAR_build_location = $BuildLocation
    $ENV:PKR_VAR_base_image = $Y.vm.tags["base_image"]
    $ENV:PKR_VAR_source_branch = $Y.vm.tags["sourceBranch"]
    $ENV:PKR_VAR_source_repository = $Y.vm.tags["sourceRepository"]
    $ENV:PKR_VAR_source_organization = $Y.vm.tags["sourceOrganization"]
    $ENV:PKR_VAR_deployment_id = $Y.vm.tags["deploymentId"]
    $ENV:PKR_VAR_worker_pool_id = $Y.vm.tags["worker_pool_id"]
    $ENV:PKR_VAR_bootstrap_script = $Y.azure["bootstrapscript"]
    $ENV:PKR_VAR_gallery_name = $Y.sharedimage["gallery_name"]
    $ENV:PKR_VAR_image_name = $Y.sharedimage["image_name"]
    $ENV:PKR_VAR_sharedimage_version = $Y.sharedimage["image_version"]
    $ENV:PKR_VAR_puppet_version = $Y.vm["puppet_version"]
    $ENV:PKR_VAR_git_version = $Y.vm["git_version"]
    #$ENV:PKR_VAR_clone_mozilla_unified = $Y.vm["clone_mozilla_unified"]

    $ENV:PKR_VAR_client_id = $Client_ID
    $ENV:PKR_VAR_application_id = $Application_ID
    $ENV:PKR_VAR_tenant_id = $Tenant_ID
    $ENV:PKR_VAR_subscription_id = $Subscription_ID
    $ENV:PKR_VAR_oidc_request_url = $oidc_request_url
    $ENV:PKR_VAR_oidc_request_token = $oidc_request_token

    # Include the build region even when the replica list is explicitly empty.
    $Locations = @(@($BuildLocation) + @($Y.azure['locations']) | ForEach-Object {
        ($_ -replace '[\s-]', '').ToLowerInvariant()
    } | Sort-Object -Unique)
    $ENV:PKR_VAR_replication_regions = ConvertTo-Json -InputObject $Locations -Compress

    $ENV:PKR_VAR_temp_resource_group_name = ('{0}-{1}-{2}-pkrtmp' -f `
        $ENV:PKR_VAR_worker_pool_id, `
        $ENV:PKR_VAR_deployment_id, `
        (Get-Random -Maximum 999))

    switch -Wildcard ($Key) {
        "*alpha2*" {
            $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-alpha2' -f $ENV:PKR_VAR_worker_pool_id, $ENV:PKR_VAR_image_sku)
        }
        "*alpha*" {
            $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-alpha' -f $ENV:PKR_VAR_worker_pool_id, $ENV:PKR_VAR_image_sku)
        }
        "*beta*" {
            $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-beta' -f $ENV:PKR_VAR_worker_pool_id, $ENV:PKR_VAR_image_sku)
        }
        "*next*" {
            $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-next' -f $ENV:PKR_VAR_worker_pool_id, $ENV:PKR_VAR_image_sku)
        }
        Default {
            $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-{2}' -f `
                $ENV:PKR_VAR_worker_pool_id, $ENV:PKR_VAR_image_sku, $ENV:PKR_VAR_deployment_id)
        }
    }

    Write-Host "Prepared $($ENV:PKR_VAR_managed_image_name) in $($ENV:PKR_VAR_temp_resource_group_name)"
    ## Set the github token for packer to use to install plugin from github
    $ENV:PACKER_GITHUB_API_TOKEN = $github_token
    if ($key -match "Trusted") {
        $ENV:PKR_VAR_use_keyvault = "true"
        $ENV:PKR_VAR_vault_name = "kv-central-us-cot"
    }
    else {
        $ENV:PKR_VAR_use_keyvault = "false"
        $ENV:PKR_VAR_vault_name = "kv-central-us-key"
    }
    Assert-AzVmSkuAvailable -SubscriptionId $Subscription_ID -Location $BuildLocation -VmSize $Y.vm['size'] -UseSpot ($Y.vm['spot'] -eq $true)
    Export-WorkerImageEnvironment
}
