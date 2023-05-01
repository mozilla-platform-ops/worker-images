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
        $publisher = $YAML.image["publisher"]
        $offer = $YAML.image["offer"]
        $sku = $YAML.image["sku"]
        $VMSize = $YAML.vm["size"]
        $baseImage = $YAML.vm.tags["base_image"]
        $SourceBranch = $YAML.vm.tags["sourceBranch"]
        $SourceRepository = $YAML.vm.tags["sourceRepository"]
        $SourceOrganization = $YAML.vm.tags["sourceOrganization"]
        $deploymentId = $YAML.vm.tags["deploymentId"]
        $BootStrapScript = $YAML.azure["bootstrapscript"]
        $WorkerPoolID = $YAML.azure["worker_pool_id"]
        Write-Output "WORKERPOOLID=$WorkerPoolID" >> $ENV:GITHUB_OUTPUT
        Write-Output "SOURCEREPOSITORY=$SourceRepository" >> $ENV:GITHUB_OUTPUT
        Write-Output "SOURCEORGANIZATION=$sourceOrganization" >> $ENV:GITHUB_OUTPUT
        Write-Output "SOURCEBRANCH=$SourceBranch" >> $ENV:GITHUB_OUTPUT
        Write-Output "DEPLOYMENTID=$deploymentId" >> $ENV:GITHUB_OUTPUT
        Write-Output "BASEIMAGE=$baseImage" >> $ENV:GITHUB_OUTPUT
        Write-Output "BOOTSTRAPSCRIPT=$BootStrapScript" >> $ENV:GITHUB_OUTPUT
        Write-Output "VMSIZE=$VMSize" >> $ENV:GITHUB_OUTPUT
        Write-Output "SKU=$sku" >> $ENV:GITHUB_OUTPUT
        Write-Output "OFFER=$offer" >> $ENV:GITHUB_OUTPUT
        Write-Output "PUBLISHER=$publisher" >> $ENV:GITHUB_OUTPUT
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
        $BootStrapScript,

        [String]
        $ImageSku,

        [String]
        $BaseImage,

        [String]
        $DeploymentId,

        [String]
        $SourceBranch,

        [String]
        $SourceOrganization,

        [String]
        $SourceRepository,

        [String]
        $WorkerPoolId,

        [String]
        $VMSize,

        [String]
        $ResourceGroup,

        [String]
        $SHA,

        [String]
        $ImageVersion,

        [String]
        $Offer
    )
    
    $ENV:PKR_VAR_offer = $Offer 
    $ENV:PKR_VAR_location = $Location
    $ENV:PKR_VAR_bootstrap_script = $BootStrapScript
    $ENV:PKR_VAR_image_sku = $ImageSku
    $ENV:PKR_VAR_base_image = $BaseImage
    $ENV:PKR_VAR_deployment_id = $DeploymentID
    $ENV:PKR_VAR_source_branch = $SourceBranch
    $ENV:PKR_VAR_source_organization = $SourceOrganization
    $ENV:PKR_VAR_source_repository = $SourceRepository
    $ENV:PKR_VAR_worker_pool_id = $WorkerPoolId
    $ENV:PKR_VAR_vm_size = $VMSize
    $ENV:PKR_VAR_resource_group = $ResourceGroup
    $ENV:PKR_VAR_client_id = $ENV:client_id
    $ENV:PKR_VAR_tenant_id = $ENV:tenant_id
    $ENV:PKR_VAR_subscription_id = $ENV:subscription_id
    $ENV:PKR_VAR_client_secret = $ENV:client_secret
    $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-alpha' -f $ENV:PKR_VAR_worker_pool_id, $ENV:PKR_VAR_image_sku)
    $ENV:PKR_VAR_image_version = $ImageVersion  
    if (Test-Path "windows.pkr.hcl") {
        packer build -force windows.pkr.hcl
    }
    else {
        Write-Error "Cannot find windows.pkr.hcl"
        Exit 1
    }
}