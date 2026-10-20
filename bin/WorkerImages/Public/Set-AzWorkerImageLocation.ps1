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

    if (-not (Test-Path $YamlPath)) {
        throw "YAML file not found at: $YamlPath"
    }

    $YAML = ConvertFrom-Yaml (Get-Content $YamlPath -Raw)

    if ($YAML.azure.locations.count -eq 1) {
        $locations = '["' + $YAML.azure.locations + '"]'
    } else {
        $locations = ($YAML.azure.locations | ConvertTo-Json -Compress)
    }

    $subscription = $YAML.azure["subscription"]
    switch ($subscription) {
        { [string]::IsNullOrEmpty($_) -or $_ -eq "tceng" } {
            $clientIdSecret = "AZURE_CLIENT_ID_TCENG"
            $subscriptionIdSecret = "AZURE_SUBSCRIPTION_ID_TCENG"
            $applicationIdSecret = "AZURE_APPLICATION_ID_TCENG"
            break
        }
        { $_ -eq "fxci-untrusted" -or $_ -eq "azure2" } {
            $clientIdSecret = "AZURE_CLIENT_ID_FXCI"
            $subscriptionIdSecret = "AZURE_SUBSCRIPTION_ID_UNTRUSTED"
            $applicationIdSecret = "AZURE_APPLICATION_ID_FXCI"
            break
        }
        default {
            throw "Unsupported Azure subscription '$subscription' in $YamlPath"
        }
    }

    Write-Output "LOCATIONS=$locations" >> $ENV:GITHUB_OUTPUT
    Write-Output "CLIENT_ID_SECRET=$clientIdSecret" >> $ENV:GITHUB_OUTPUT
    Write-Output "SUBSCRIPTION_ID_SECRET=$subscriptionIdSecret" >> $ENV:GITHUB_OUTPUT
    Write-Output "APPLICATION_ID_SECRET=$applicationIdSecret" >> $ENV:GITHUB_OUTPUT
}
