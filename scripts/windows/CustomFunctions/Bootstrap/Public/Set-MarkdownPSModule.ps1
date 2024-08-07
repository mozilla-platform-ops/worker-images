function Set-MarkdownPSModule {
    [CmdletBinding()]
    param (

    )

    Write-Log -message ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    Write-Host ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime())
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    ## Bootstrap for powershell modules
    Get-PackageProvider -Name Nuget -ForceBootstrap | Out-Null
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

    ## install MarkdownPS
    Install-Module -Name "MarkdownPS" -Force
    Write-Log -message  ('{0} :: Installed MarkdownPS' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'

}
