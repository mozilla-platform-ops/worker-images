function Remove-AzWorkerImage {
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
    if ([string]::IsNullOrEmpty($YAML)) {
        throw "Unable to config using $key. Exiting!"
        exit 1
    }
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
    if ([string]::IsNullOrEmpty($managed_image_name)) {
        throw "Unable to find managed image name. Exiting!"
        exit 1
    }
    ## The number of images returned should only be the number of locations, if there are more exit
    $locations = $yaml.azure.locations.count
    $Image = Get-AzImage -Name $managed_image_name
    if ($image.count -gt $locations) {
        throw "Unable to find managed image name. Exiting!"
        exit 1
    }
    ## If image is has a result and it's equal or less than the number of locations in the config, remove it
    if ((-not [string]::IsNullOrEmpty($managed_image_name)) -and $image.count -le $locations) {
        Write-Host "Removing $($managed_image_name)"
        Get-AzImage -Name $managed_image_name | Remove-AzImage -Force
    }
    else {
        Write-Host "Image $($managed_image_name) not found, continuing"
    }
}