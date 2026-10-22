Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Register-PSRepository -Default -InstallationPolicy Trusted -ErrorAction SilentlyContinue
Install-Module powershell-yaml -Force
