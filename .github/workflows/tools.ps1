function Set-WorkerImageOutput {
    [CmdletBinding()]
    param (
        [Parameter()]
        [String]
        $CommitMessage
    )
    
    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module powershell-yaml -ErrorAction Stop
    $Commit = ConvertFrom-Json $CommitMessage
    ## Handle the pools and pluck them out
    $keys_index = $commit.IndexOf("keys:")
    $keys = if ($keys_index -ne -1) {
        $keys_value = $commit.Substring($keys_index + 5).Trim()
        if ($keys_value -match ",") {
            $keys_array = $keys_value.Split(",")
            foreach ($key in $keys_array) {
                $key.Trim()
            }
        }
        else {
            $keys_value.Trim()
        }
    }
    Foreach ($key in $keys) {
        $YAML = Convertfrom-Yaml (Get-Content "config/$key.yaml" -raw)
        $locations = ($YAML.azure.locations | ConvertTo-Json -Compress)
        Write-Output "LOCATIONS=$locations" >> $ENV:GITHUB_OUTPUT
        Write-Output "KEY=$Key" >> $ENV:GITHUB_OUTPUT
    }
}

function Set-WorkerImageLocation {
    [CmdletBinding()]
    param (
        [Parameter()]
        [String]
        $Key
    )
    
    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module powershell-yaml -ErrorAction Stop
    $YAML = Convertfrom-Yaml (Get-Content "config/$key.yaml" -raw)
    if ($YAML.azure.locations.count -eq 1) {
        $locations = '["' + $yaml.azure.locations + '"]'
    } else {
        $locations = ($YAML.azure.locations | ConvertTo-Json -Compress)
    }
    Write-Output "LOCATIONS=$locations" >> $ENV:GITHUB_OUTPUT
    
}

function New-SharedWorkerImage {
    [CmdletBinding()]
    param (
        [String]
        $Key,

        [String]
        $Client_ID,

        [String]
        $Client_Secret,

        [String]
        $Subscription_ID,

        [String]
        $Tenant_ID
    )

    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module powershell-yaml -ErrorAction Stop
    $YAML = Convertfrom-Yaml (Get-Content "config/$key.yaml" -raw)
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
    $ENV:PKR_VAR_client_id = $Client_ID
    $ENV:PKR_VAR_temp_resource_group_name = ('{0}-{1}-{2}-pkrtmp' -f $YAML.vm.tags["worker_pool_id"], $YAML.vm.tags["deploymentId"], (Get-Random -Maximum 999))
    $ENV:PKR_VAR_tenant_id = $Tenant_ID
    $ENV:PKR_VAR_subscription_id = $Subscription_ID
    $ENV:PKR_VAR_client_secret = $Client_Secret
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
    packer build --only azure-arm.sig -force azure.pkr.hcl
}

function New-WorkerImage {
    [CmdletBinding()]
    param (
        [String]
        $Key,

        [String]
        $Location,

        [String]
        $Client_ID,

        [String]
        $Client_Secret,

        [String]
        $Subscription_ID,

        [String]
        $Tenant_ID
    )

    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module powershell-yaml -ErrorAction Stop
    $YAML = Convertfrom-Yaml (Get-Content "config/$key.yaml" -raw)
    $ENV:PKR_VAR_location = $Location
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
    $ENV:PKR_VAR_client_id = $Client_ID
    $ENV:PKR_VAR_temp_resource_group_name = ('{0}-{1}-{2}-pkrtmp' -f $YAML.vm.tags["worker_pool_id"], $YAML.vm.tags["deploymentId"], (Get-Random -Maximum 999))
    $ENV:PKR_VAR_tenant_id = $Tenant_ID
    $ENV:PKR_VAR_subscription_id = $Subscription_ID
    $ENV:PKR_VAR_client_secret = $Client_Secret
    switch -Wildcard ($key) {
        "*alpha2*" {
            $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-{2}-alpha2' -f $YAML.vm.tags["worker_pool_id"], $Location, $ENV:PKR_VAR_image_sku)
        }
        "*alpha*" {
            $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-{2}-alpha' -f $YAML.vm.tags["worker_pool_id"], $Location, $ENV:PKR_VAR_image_sku)
        }
        "*beta*" {
            $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-{2}-beta' -f $YAML.vm.tags["worker_pool_id"], $Location, $ENV:PKR_VAR_image_sku)
        }
        "*next*" {
            $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-{2}-next' -f $YAML.vm.tags["worker_pool_id"], $Location, $ENV:PKR_VAR_image_sku)
        } 
        Default {
            $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-{2}-{3}' -f $YAML.vm.tags["worker_pool_id"], $Location, $ENV:PKR_VAR_image_sku, $YAML.vm.tags["deploymentId"])
        }
    }
    packer build --only azure-arm.nonsig -force azure.pkr.hcl
}

function Remove-WorkerImage {
    [CmdletBinding()]
    param (
        [String]
        $Key,

        [String]
        $Location
    )

    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module powershell-yaml -ErrorAction Stop
    $YAML = Convertfrom-Yaml (Get-Content "config/$key.yaml" -raw)
    ## build managed image name 
    switch -Wildcard ($key) {
        "*alpha2*" {
            $managed_image_name = ('{0}-{1}-{2}-alpha2' -f $YAML.vm.tags["worker_pool_id"], $Location, $YAML.image["sku"])
        }
        "*alpha*" {
            $managed_image_name = ('{0}-{1}-{2}-alpha' -f $YAML.vm.tags["worker_pool_id"], $Location, $YAML.image["sku"])
        }
        "*beta*" {
            $managed_image_name = ('{0}-{1}-{2}-beta' -f $YAML.vm.tags["worker_pool_id"], $Location, $YAML.image["sku"])
        }
        "*next*" {
            $managed_image_name = ('{0}-{1}-{2}-next' -f $YAML.vm.tags["worker_pool_id"], $Location, $YAML.image["sku"])
        } 
        Default {
            $managed_image_name = ('{0}-{1}-{2}-{3}' -f $YAML.vm.tags["worker_pool_id"], $Location, $YAML.image["sku"], $YAML.vm.tags["deploymentId"])
        }
    }
    ## Check if the image is even there
    $Image = Get-AzImage -Name $managed_image_name
    if ($null -ne $image) {
        Write-Host "Removing $($managed_image_name)"
        Get-AzImage -Name $managed_image_name | Remove-AzImage -Force
    }
    else {
        Write-Host "Image $($managed_image_name) not found, continuing"
    }
}

function Remove-VMImageVersion {
    [CmdletBinding()]
    param (
        [String]
        $Key
    )

    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module powershell-yaml -ErrorAction Stop
    $YAML = Convertfrom-Yaml (Get-Content "config/$key.yaml" -raw)
    ## Check if the image version is there
    $splat = @{
        ResourceGroupName = $YAML.azure["managed_image_resource_group_name"]
        GalleryName = $YAML.sharedimage["gallery_name"]
        GalleryImageDefinitionName = $YAML.sharedimage["image_name"]
        GalleryImageVersionName = $YAML.sharedimage["image_version"]
    }
    try {
        Get-AzGalleryImageVersion @splat -ErrorAction "Stop"
        Write-Host "Removing $($splat.GalleryImageVersionName)"
        Remove-AzGalleryImageVersion @splat -Force
    }
    catch {
        Write-Host "ImageVersion $($splat.GalleryImageVersionName) not found, continuing"
    }
}