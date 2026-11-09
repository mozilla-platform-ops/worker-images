[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Project,
    [Parameter(Mandatory)][string] $ImageName
)

$ErrorActionPreference = 'Stop'
$ImageReference = "projects/$Project/global/images/$ImageName"
$FxciConfigUrl = 'https://raw.githubusercontent.com/mozilla-releng/fxci-config/main/worker-images.yml'
$WorkerImages = (Invoke-WebRequest -Uri $FxciConfigUrl -ErrorAction Stop).Content

if ($WorkerImages.Contains($ImageReference)) {
    throw "Refusing to delete ${ImageReference}: fxci-config/main references this image."
}

Write-Host "fxci-config/main does not reference $ImageReference."
