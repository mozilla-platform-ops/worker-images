function Set-GCPWorkerImageName {
    [CmdletBinding()]
    param (
        [String]
        $Key
    )
    
    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module powershell-yaml -ErrorAction Stop
    $YAML = Convertfrom-Yaml (Get-Content "config/$key.yaml" -raw)
    $ImageName = $YAML.image["image_name"]
    Write-Host "Setting $ImageName as the name for the worker image"
    Write-Output "IMAGENAME=$ImageName" >> $ENV:GITHUB_OUTPUT
}