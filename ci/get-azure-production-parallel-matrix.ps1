Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Set-OutputValue {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,
        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    if ($env:GITHUB_OUTPUT) {
        "$Name=$Value" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
        return
    }

    Write-Output "$Name=$Value"
}

$yaml = ConvertFrom-Yaml (Get-Content "./config/windows_production_defaults.yaml" -Raw)
$prodImages = @($yaml.images.production)
$trustedImages = @(
    Get-ChildItem -Path "./config" -File -Filter "trusted-*.yaml" |
        ForEach-Object { $_.BaseName } |
        Where-Object { $_ -match "^trusted-(?!gw-fxci-gcp).*" -and $_ -notmatch "alpha" } |
        Sort-Object
)

if (-not $prodImages -or $prodImages.Count -eq 0) {
    Write-Host "::error ::No untrusted production images found in YAML"
    exit 1
}

$matrixEntries = @()
foreach ($config in $prodImages) {
    $matrixEntries += @{
        config = $config
        client_id_secret = "AZURE_CLIENT_ID_FXCI"
        subscription_id_secret = "AZURE_SUBSCRIPTION_ID_UNTRUSTED"
        application_id_secret = "AZURE_APPLICATION_ID_FXCI"
        run_os_integration = ($config -notmatch "^win2022" -and $config -notmatch "^win11-a64.*builder")
    }
}

foreach ($config in $trustedImages) {
    $matrixEntries += @{
        config = $config
        client_id_secret = "AZURE_CLIENT_ID_FXCI_TRUSTED"
        subscription_id_secret = "AZURE_SUBSCRIPTION_ID_TRUSTED"
        application_id_secret = "AZURE_APPLICATION_ID_FXCI_TRUSTED"
        run_os_integration = $false
    }
}

$matrix = @{ include = @($matrixEntries) } | ConvertTo-Json -Compress -Depth 10
Write-Host "Generated matrix: $matrix"
Set-OutputValue -Name "matrix" -Value $matrix

$osIntegrationEntries = @(
    $matrixEntries |
        Where-Object { $_.run_os_integration } |
        ForEach-Object { @{ config = $_.config } }
)
$osIntegrationMatrix = @{ include = @($osIntegrationEntries) } | ConvertTo-Json -Compress -Depth 10
Write-Host "Generated os-integration matrix: $osIntegrationMatrix"
Set-OutputValue -Name "os_integration_matrix" -Value $osIntegrationMatrix
