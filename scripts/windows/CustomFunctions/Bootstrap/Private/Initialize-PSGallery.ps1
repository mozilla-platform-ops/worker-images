function Initialize-PSGallery {
    [CmdletBinding()]
    param()

    # PSRepository registrations are per-user. Packer provisions images as
    # SYSTEM while the base image normally registers PSGallery for its build
    # user, so the repository is frequently missing here.
    if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
        Write-Log -message ('{0} :: PSGallery is not registered; registering it' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'
        Register-PSRepository -Default -InstallationPolicy Trusted -ErrorAction Stop | Out-Null
        return
    }

    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
}
