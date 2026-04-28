Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Set-PSRepository PSGallery -InstallationPolicy Trusted
Install-Module powershell-yaml -Force
