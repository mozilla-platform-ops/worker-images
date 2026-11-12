function Test-GCPImageReferencedInFxciConfig {
    <#
    .SYNOPSIS
    Checks whether production fxci-config references a GCP image.

    .PARAMETER Project
    GCP project that owns the image.

    .PARAMETER ImageName
    Name of the GCP image.

    .OUTPUTS
    System.Boolean
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Project,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ImageName
    )

    $imageReference = "projects/$Project/global/images/$ImageName"
    $fxciConfigUrl = 'https://raw.githubusercontent.com/mozilla-releng/fxci-config/main/worker-images.yml'
    $workerImages = (Invoke-WebRequest -Uri $fxciConfigUrl -ErrorAction Stop).Content

    return [bool]$workerImages.Contains($imageReference)
}
