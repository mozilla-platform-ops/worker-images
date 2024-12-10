function New-AzSharedWorkerImage {
    [CmdletBinding()]
    param (
        [String]
        $Key,

        [String]
        $Client_ID,

        [String]
        $Client_Secret,

        [String]
        $Application_ID,

        [String]
        $oidc_request_url,

        [String]
        $oidc_request_token,

        [String]
        $Subscription_ID,

        [String]
        $Tenant_ID
    )

    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module powershell-yaml -ErrorAction Stop
    $YAML = Convertfrom-Yaml (Get-Content "config/$key.yaml" -raw)
    $ENV:PKR_VAR_config = $key
    $ENV:PKR_VAR_image_key_name = $key
    $ENV:PKR_VAR_image_publisher = $YAML.image["publisher"]
    $ENV:PKR_VAR_resource_group = $yaml.azure["managed_image_resource_group_name"]
    $ENV:PKR_VAR_image_offer = $YAML.image["offer"]
    $ENV:PKR_VAR_image_sku = $YAML.image["sku"]
    $ENV:PKR_VAR_image_version = $YAML.image["version"]
    $ENV:PKR_VAR_vm_size = $YAML.vm["size"]
    $ENV:PKR_VAR_base_image = $YAML.vm.tags["base_image"]
    $ENV:PKR_VAR_source_branch = $YAML.vm.tags["sourceBranch"]
    $ENV:PKR_VAR_source_repository = $YAML.vm.tags["sourceRepository"]
    $ENV:PKR_VAR_source_organization = $YAML.vm.tags["sourceOrganization"]
    $ENV:PKR_VAR_deployment_id = $YAML.vm.tags["deploymentId"]
    $ENV:PKR_VAR_bootstrap_script = $YAML.azure["bootstrapscript"]
    $ENV:PKR_VAR_gallery_name = $YAML.sharedimage["gallery_name"]
    $ENV:PKR_VAR_image_name = $YAML.sharedimage["image_name"]
    $ENV:PKR_VAR_sharedimage_version = $YAML.sharedimage["image_version"]
    $ENV:PKR_VAR_image_locations = $YAML.azure["locations"]
    $ENV:PKR_VAR_client_id = $Client_ID
    $ENV:PKR_VAR_temp_resource_group_name = ('{0}-{1}-{2}-pkrtmp' -f $YAML.vm.tags["worker_pool_id"], $YAML.vm.tags["deploymentId"], (Get-Random -Maximum 999))
    $ENV:PKR_VAR_tenant_id = $Tenant_ID
    $ENV:PKR_VAR_subscription_id = $Subscription_ID
    $ENV:PKR_VAR_application_id = $Application_ID
    $ENV:PKR_VAR_oidc_request_url = $oidc_request_url
    $ENV:PKR_VAR_oidc_request_token = $oidc_request_token
    $ENV:PKR_VAR_worker_pool_id = $YAML.vm.tags["worker_pool_id"]
    switch -Wildcard ($key) {
        "*alpha2*" {
            $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-alpha2' -f $YAML.vm.tags["worker_pool_id"], $ENV:PKR_VAR_image_sku)
        }
        "*alpha*" {
            $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-alpha' -f $YAML.vm.tags["worker_pool_id"], $ENV:PKR_VAR_image_sku)
        }
        "*beta*" {
            $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-beta' -f $YAML.vm.tags["worker_pool_id"], $ENV:PKR_VAR_image_sku)
        }
        "*next*" {
            $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-next' -f $YAML.vm.tags["worker_pool_id"],  $ENV:PKR_VAR_image_sku)
        } 
        Default {
            $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-{2}' -f $YAML.vm.tags["worker_pool_id"], $ENV:PKR_VAR_image_sku, $YAML.vm.tags["deploymentId"])
        }
    }
    Write-Host "Building $($ENV:PKR_VAR_managed_image_name) in $($ENV:PKR_VAR_temp_resource_group_name)"
    packer init azure.pkr.hcl
    packer build --only azure-arm.sig -force azure.pkr.hcl
}
