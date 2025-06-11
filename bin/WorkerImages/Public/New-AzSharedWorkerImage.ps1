function New-AzSharedWorkerImage {
    [CmdletBinding()]
    param (
        [String] $Key,
        [String] $Client_ID,
        [String] $Client_Secret,
        [String] $Application_ID,
        [String] $oidc_request_url,
        [String] $oidc_request_token,
        [String] $Subscription_ID,
        [String] $Tenant_ID
    )

    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module powershell-yaml -ErrorAction Stop

    $DefaultYaml = ConvertFrom-Yaml (Get-Content "config/windows_production_defualts.yaml" -Raw)
    $ImageYaml = ConvertFrom-Yaml (Get-Content "config/$Key.yaml" -Raw)

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
            elseif ($null -ne $imageVal -and $imageVal -ne '' -and $imageVal -ne 'default') {
                $merged[$key] = $imageVal
            }
            elseif ($null -ne $defaultVal) {
                $merged[$key] = $defaultVal
            }
        }
        return $merged
    }

    $Y = Merge-YamlWithDefaults -ImageData $ImageYaml -DefaultData $DefaultYaml

    # Resolve Puppet and Git versions
    $puppetVersion = $Y.vm["puppet_version"]
    if ($puppetVersion -eq "default" -or [string]::IsNullOrEmpty($puppetVersion)) {
        $puppetVersion = $DefaultYaml.vm["puppet_version"]
    }
    $ENV:PKR_VAR_puppet_version = $puppetVersion

    $gitVersion = $Y.vm["git_version"]
    if ($gitVersion -eq "default" -or [string]::IsNullOrEmpty($gitVersion)) {
        $gitVersion = $DefaultYaml.vm["git_version"]
    }
    $ENV:PKR_VAR_git_version = $gitVersion

    # Required Packer vars
    $ENV:PKR_VAR_config = $Key
    $ENV:PKR_VAR_image_key_name = $Key
    $ENV:PKR_VAR_image_publisher = $Y.image["publisher"]
    $ENV:PKR_VAR_image_offer = $Y.image["offer"]
    $ENV:PKR_VAR_image_sku = $Y.image["sku"]
    $ENV:PKR_VAR_image_version = $Y.image["version"]
    $ENV:PKR_VAR_resource_group = $Y.azure["managed_image_resource_group_name"]
    $ENV:PKR_VAR_vm_size = $Y.vm["size"]
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

    # Auth & config vars
    $ENV:PKR_VAR_client_id = $Client_ID
    $ENV:PKR_VAR_application_id = $Application_ID
    $ENV:PKR_VAR_tenant_id = $Tenant_ID
    $ENV:PKR_VAR_subscription_id = $Subscription_ID
    $ENV:PKR_VAR_oidc_request_url = $oidc_request_url
    $ENV:PKR_VAR_oidc_request_token = $oidc_request_token

    # Derived name
    $ENV:PKR_VAR_temp_resource_group_name = ('{0}-{1}-{2}-pkrtmp' -f $ENV:PKR_VAR_worker_pool_id, $ENV:PKR_VAR_deployment_id, (Get-Random -Maximum 999))

    # Image name logic
    switch -Wildcard ($Key) {
        "*alpha2*" {
            $PackerForceBuild = $true
            $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-alpha2' -f $ENV:PKR_VAR_worker_pool_id, $ENV:PKR_VAR_image_sku)
        }
        "*alpha*" {
            $PackerForceBuild = $true
            $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-alpha' -f $ENV:PKR_VAR_worker_pool_id, $ENV:PKR_VAR_image_sku)
        }
        "*beta*" {
            $PackerForceBuild = $true
            $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-beta' -f $ENV:PKR_VAR_worker_pool_id, $ENV:PKR_VAR_image_sku)
        }
        "*next*" {
            $PackerForceBuild = $true
            $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-next' -f $ENV:PKR_VAR_worker_pool_id, $ENV:PKR_VAR_image_sku)
        }
        Default {
            $PackerForceBuild = $false
            $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-{2}' -f $ENV:PKR_VAR_worker_pool_id, $ENV:PKR_VAR_image_sku, $ENV:PKR_VAR_deployment_id)
        }
    }

    Write-Host "Building $($ENV:PKR_VAR_managed_image_name) in $($ENV:PKR_VAR_temp_resource_group_name)"
    packer init azure.pkr.hcl
    if ($PackerForceBuild) {
        packer build --only azure-arm.sig -force azure.pkr.hcl
    } else {
        packer build --only azure-arm.sig azure.pkr.hcl
    }
}