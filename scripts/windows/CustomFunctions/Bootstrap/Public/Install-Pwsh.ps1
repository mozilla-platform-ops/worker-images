function Install-Pwsh {
    [CmdletBinding()]
    param (
        [String]
        $Version
    )

    Write-Log -message ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    Write-Host ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime())
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    ## Bootstrap for powershell modules
    Get-PackageProvider -Name Nuget -ForceBootstrap | Out-Null
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

    ## Install PSReleaseTools
    Install-Module -Name "PSReleaseTools" -Force
    Write-Log -message  ('{0} :: Installed PSReleaseTools' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'

    ## Install pwsh
    Install-PowerShell -Mode Quiet
}