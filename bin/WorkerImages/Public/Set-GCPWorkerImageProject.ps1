function Set-GCPWorkerImageProject {
    [CmdletBinding()]
    param (
        [String]
        $Key
    )
    
    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module powershell-yaml -ErrorAction Stop
    $YAML = Convertfrom-Yaml (Get-Content "config/$key.yaml" -raw)
    $Project = $YAML.image["project_id"]
    Write-Host "Setting $Project as the project for the worker image"
    Write-Output "PROJECT=$Project" >> $ENV:GITHUB_OUTPUT
}