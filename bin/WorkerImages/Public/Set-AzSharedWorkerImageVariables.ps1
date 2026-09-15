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

    function Merge-YamlWithDefaults {
        param (
            [hashtable] $ImageData,
            [hashtable] $DefaultData
        )
        $merged = @{}
        $allKeys = $ImageData.Keys + $DefaultData.Keys | Select-Object -Unique
        foreach ($key in $allKeys) {
            $imageVal = $ImageData[$key]
            $defaultVal = $DefaultData[$key]

            if ($imageVal -is [hashtable] -and $defaultVal -is [hashtable]) {
                $merged[$key] = Merge-YamlWithDefaults -ImageData $imageVal -DefaultData $defaultVal
            }
            elseif ($imageVal -is [System.Collections.IEnumerable] -and
                    -not ($imageVal -is [string]) -and
                    $imageVal.Count -gt 0) {
                $merged[$key] = $imageVal
            }
            elseif ($imageVal -is [string] -and $imageVal -eq 'default' -and $null -ne $defaultVal -and $defaultVal -ne 'default') {
                $merged[$key] = $defaultVal
            }
            elseif ($null -ne $imageVal -and ($imageVal -isnot [string] -or ($imageVal -ne '' -and $imageVal -ne 'default'))) {
                $merged[$key] = $imageVal
            }
            elseif ($null -ne $defaultVal -and $defaultVal -ne 'default') {
                $merged[$key] = $defaultVal
            }
        }
        return $merged
    }

    function Log-FinalValue {
        param (
            [string] $Label,
            [string] $Final,
            [string] $Image
        )
        if ($Image -eq $Final) {
            Write-Host "$Label = $Final (from image YAML)"
        }
        elseif ($Final -eq 'default') {
            Write-Host "$Label = default ⚠️  (not overridden!)"
        }
        else {
            Write-Host "$Label = $Final (overridden by default YAML)"
        }
    }

    $Y = Merge-YamlWithDefaults -ImageData $ImageYaml -DefaultData $DefaultYaml

    # Debug logging
    Log-FinalValue "openvox_version"    $Y.vm["openvox_version"] $ImageYaml.vm["openvox_version"]
    Log-FinalValue "puppet_version"     $Y.vm["puppet_version"] $ImageYaml.vm["puppet_version"]
    Log-FinalValue "git_version"        $Y.vm["git_version"]    $ImageYaml.vm["git_version"]
    #Log-FinalValue "clone_mozilla_unified" $Y.vm["clone_mozilla_unified"] $ImageYaml.vm["clone_mozilla_unified"] $DefaultYaml.vm["clone_mozilla_unified"]
    Log-FinalValue "sourceBranch"        $Y.vm.tags["sourceBranch"]        $ImageYaml.vm.tags["sourceBranch"]
    Log-FinalValue "sourceRepository"    $Y.vm.tags["sourceRepository"]    $ImageYaml.vm.tags["sourceRepository"]
    Log-FinalValue "sourceOrganization"  $Y.vm.tags["sourceOrganization"]  $ImageYaml.vm.tags["sourceOrganization"]
    Log-FinalValue "deploymentId"        $Y.vm.tags["deploymentId"]        $ImageYaml.vm.tags["deploymentId"]
    Log-FinalValue "resource_group"      $Y.azure["managed_image_resource_group_name"] $ImageYaml.azure["managed_image_resource_group_name"]
    Log-FinalValue "vmSize"              $Y.vm["size"]                     $ImageYaml.vm["size"]
    Log-FinalValue "spot"                $Y.vm["spot"]                     $ImageYaml.vm["spot"]
    Log-FinalValue "build_location"      $Y.azure["build_location"]        $ImageYaml.azure["build_location"]

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

    # Set replication regions from config locations (HCL list format for Packer)
    $Locations = $Y.azure["locations"]
    if ($Locations -and $Locations.Count -gt 0) {
        $RegionsHcl = '["' + ($Locations -join '", "') + '"]'
        $ENV:PKR_VAR_replication_regions = $RegionsHcl
        Write-Host "Replication regions: $RegionsHcl"
    } else {
        Write-Host "WARNING: No locations specified in config, using Packer default"
    }

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
    Export-WorkerImageEnvironment
}
