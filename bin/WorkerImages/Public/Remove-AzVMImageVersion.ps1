function Remove-AzVMImageVersion {
    [CmdletBinding()]
    param (
        [String]
        $Key
    )

    #Set-PSRepository PSGallery -InstallationPolicy Trusted
    #Install-Module powershell-yaml -ErrorAction Stop
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