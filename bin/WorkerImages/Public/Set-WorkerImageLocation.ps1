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