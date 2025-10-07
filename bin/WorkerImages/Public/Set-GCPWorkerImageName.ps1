function Set-GCPWorkerImageName {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [String] $Key,
        [Parameter(Mandatory = $false)]
        [String] $Team
    )
    
    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module powershell-yaml -ErrorAction Stop

    if ($Team -and $Team -ieq "tceng") {
        $YamlPath = "config/tceng/$Key.yaml"
    } else {
        $YamlPath = "config/$Key.yaml"
    }

    if (-not (Test-Path $YamlPath)) {
        throw "YAML file not found at: $YamlPath"
    }

    $YAML = ConvertFrom-Yaml (Get-Content $YamlPath -Raw)

    if ($Key -notmatch "alpha") {
        $suffix = Get-Date -Format "yyyy-MM-dd"
        $ImageName = -join ($YAML.image["image_name"], "-", $suffix)
    } else {
        $ImageName = $YAML.image["image_name"]
    }

    Write-Host "Setting $ImageName as the name for the worker image"

    if ($env:GITHUB_OUTPUT) {
        "IMAGENAME=$ImageName" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
    } else {
        Write-Output "IMAGENAME=$ImageName"
    }
}