function Get-AzureProductionParallelMatrix {
    <#
    .SYNOPSIS
    Builds the Azure production and OS integration matrices.

    .PARAMETER BuildDate
    UTC build date in yyyy-MM-dd format. Defaults to today's UTC date.

    .OUTPUTS
    System.Management.Automation.PSCustomObject with BuildDate, Matrix, and
    OsIntegrationMatrix properties.
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [string] $BuildDate = $env:BUILD_DATE
    )

    if ([string]::IsNullOrWhiteSpace($BuildDate)) {
        $BuildDate = [DateTime]::UtcNow.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    }

    try {
        $BuildDate = [DateTime]::ParseExact(
            $BuildDate,
            'yyyy-MM-dd',
            [Globalization.CultureInfo]::InvariantCulture
        ).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    } catch {
        throw "BuildDate must use yyyy-MM-dd format. Value: '$BuildDate'."
    }

    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
    $configPath = Join-Path $repositoryRoot 'config'
    $defaultsPath = Join-Path $configPath 'windows_production_defaults.yaml'
    if (-not (Test-Path -LiteralPath $defaultsPath -PathType Leaf)) {
        throw "Windows production defaults not found: $defaultsPath"
    }

    $yaml = ConvertFrom-Yaml (Get-Content -LiteralPath $defaultsPath -Raw)
    $productionImages = @($yaml.images.production)
    if ($productionImages.Count -eq 0) {
        throw 'No untrusted production images found in windows_production_defaults.yaml.'
    }

    $trustedImages = @(
        Get-ChildItem -LiteralPath $configPath -File -Filter 'trusted-*.yaml' |
            ForEach-Object { $_.BaseName } |
            Where-Object { $_ -match '^trusted-(?!gw-fxci-gcp).*' -and $_ -notmatch 'alpha|core' } |
            Sort-Object
    )

    $matrixEntries = @(
        foreach ($config in $productionImages) {
            @{
                config = $config
                client_id_secret = 'AZURE_CLIENT_ID_FXCI'
                subscription_id_secret = 'AZURE_SUBSCRIPTION_ID_UNTRUSTED'
                application_id_secret = 'AZURE_APPLICATION_ID_FXCI'
                run_os_integration = ($config -notmatch '^win2022' -and $config -notmatch '^win11-a64.*builder')
            }
        }
        foreach ($config in $trustedImages) {
            @{
                config = $config
                client_id_secret = 'AZURE_CLIENT_ID_FXCI_TRUSTED'
                subscription_id_secret = 'AZURE_SUBSCRIPTION_ID_TRUSTED'
                application_id_secret = 'AZURE_APPLICATION_ID_FXCI_TRUSTED'
                run_os_integration = $false
            }
        }
    )

    $matrix = @{ include = @($matrixEntries) } | ConvertTo-Json -Compress -Depth 10
    $osIntegrationEntries = @(
        $matrixEntries |
            Where-Object { $_.run_os_integration } |
            ForEach-Object { @{ config = $_.config } }
    )
    $osIntegrationMatrix = @{ include = @($osIntegrationEntries) } | ConvertTo-Json -Compress -Depth 10

    return [pscustomobject]@{
        BuildDate            = $BuildDate
        Matrix               = $matrix
        OsIntegrationMatrix  = $osIntegrationMatrix
    }
}
