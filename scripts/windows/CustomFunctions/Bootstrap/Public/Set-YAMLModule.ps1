function Set-YAMLModule {
    [CmdletBinding()]
    param (

    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    ## Bootstrap for powershell modules
    Get-PackageProvider -Name Nuget -ForceBootstrap | Out-Null
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

    ## install Pester
    Install-Module -Name "Powershell-YAML" -Force
    Write-Log -message  ('{0} :: Installed Powershell-YAML' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'

}
