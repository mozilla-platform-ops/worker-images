function Remove-AzWorkerImage {
    [CmdletBinding()]
    param (
        [String]
        $Key,

        [String]
        $Location
    )

    #Set-PSRepository PSGallery -InstallationPolicy Trusted
    #Install-Module powershell-yaml -ErrorAction Stop
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