function Set-PesterVersion {
    [CmdletBinding()]
    param (

    )

    Write-Log -message ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    Write-Host ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime())
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    ## Bootstrap for powershell modules
    Get-PackageProvider -Name Nuget -ForceBootstrap | Out-Null
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

    Foreach ($module in @("C:\Program Files (x86)\WindowsPowerShell\Modules\Pester", "C:\Program Files\WindowsPowerShell\Modules\Pester")) {
        takeown /F $module /A /R | Out-Null
        icacls $module /reset | Out-Null
        icacls $module /grant "*S-1-5-32-544:F" /inheritance:d /T | Out-Null
        Remove-Item -Path $module -Recurse -Force -Confirm:$false | Out-Null
    }

    ## install Pester
    Install-Module -Name Pester -Force

    Write-Log -message  ('{0} :: Pester 5 installation appears complete' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'

}
