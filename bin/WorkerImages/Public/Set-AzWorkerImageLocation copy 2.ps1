function Set-AzWorkerImageLocation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [String] $Key,

        [Parameter(Mandatory = $false)]
        [String] $Team
    )

    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module powershell-yaml -ErrorAction Stop

    if ($Team) {
        $YamlPath = "config/$Team/$Key.yaml"
    } else {
        $YamlPath = "config/$Key.yaml"
    }

    Write-Host "Resolved YAML path: $YamlPath"

    if (-not (Test-Path $YamlPath)) {
        throw "YAML file not found at: $YamlPath"
    }

    $YAML = ConvertFrom-Yaml (Get-Content $YamlPath -Raw)

    if (-not $YAML.azure -or -not $YAML.azure.locations) {
        throw "Missing or empty 'azure.locations' key in YAML file."
    }

    Write-Host "Found azure.locations: $($YAML.azure.locations -join ', ')"

    if ($YAML.azure.locations.count -eq 1) {
        $locations = '["' + $YAML.azure.locations + '"]'
    } else {
        $locations = ($YAML.azure.locations | ConvertTo-Json -Compress)
    }

    Write-Host "Exporting LOCATIONS=$locations"
    "LOCATIONS=$locations" >> $env:GITHUB_OUTPUT
}
