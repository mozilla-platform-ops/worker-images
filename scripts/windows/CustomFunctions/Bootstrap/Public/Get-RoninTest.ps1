function Get-RoninTest {
    [CmdletBinding()]
    param (
        [String]
        $Key
    )

    ## Install Powershell YAML module
    Get-PackageProvider -Name Nuget -ForceBootstrap | Out-Null
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module -Name "PowerShell-Yaml" -Repository PSGallery -Force

    ## Get just the tests that are defined in the config
    $Hiera = Convertfrom-Yaml (Get-Content -Path "C:\ronin\data\roles\$key.yaml" -Raw)

    ## Loop through the tests based on which ones were selected
    $hiera.tests | ForEach-Object {
        $name = $psitem
        Get-ChildItem -Path "C:/Tests/*" -Filter "*$name*"
    }
}