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

function New-WorkerImage {
    [CmdletBinding()]
    param (
        [String]
        $Location,

        [String]
        $CommitMessage,

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
        $ENV:PKR_VAR_location = $Location
        $ENV:PKR_VAR_image_publisher = $YAML.image["publisher"]
        $ENV:PKR_VAR_resource_group = $yaml.azure["managed_image_resource_group_name"]
        $ENV:PKR_VAR_image_offer = $YAML.image["offer"]
        $ENV:PKR_VAR_image_sku = $YAML.image["sku"]
        $ENV:PKR_VAR_vm_size = $YAML.vm["size"]
        $ENV:PKR_VAR_base_image = $YAML.vm.tags["base_image"]
        $ENV:PKR_VAR_source_branch = $YAML.vm.tags["sourceBranch"]
        $ENV:PKR_VAR_source_repository = $YAML.vm.tags["sourceRepository"]
        $ENV:PKR_VAR_source_organization = $YAML.vm.tags["sourceOrganization"]
        $ENV:PKR_VAR_deployment_id = $YAML.vm.tags["deploymentId"]
        $ENV:PKR_VAR_bootstrap_script = $YAML.azure["bootstrapscript"]
        $ENV:PKR_VAR_client_id = $Client_ID
        $ENV:PKR_VAR_temp_resource_group_name = ('{0}-{1}-{2}-{3}-pkrtmp' -f $YAML.vm.tags["worker_pool_id"], $ENV:PKR_VAR_location, $YAML.vm.tags["deploymentId"], (Get-Random -Maximum 999))
        $ENV:PKR_VAR_tenant_id = $Tenant_ID
        $ENV:PKR_VAR_subscription_id = $Subscription_ID
        $ENV:PKR_VAR_client_secret = $Client_Secret
        $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-alpha' -f $YAML.vm.tags["worker_pool_id"], $ENV:PKR_VAR_image_sku)
        Write-Host "Building $($ENV:PKR_VAR_managed_image_name)"
        $ENV:PKR_VAR_image_version = $ImageVersion
        if (Test-Path "./windows/windows.pkr.hcl") {
            packer build -force ./windows/windows.pkr.hcl
        }
        else {
            Write-Error "Cannot find ./windows/windows.pkr.hcl"
            Exit 1
        }
    }
}