function Set-GCPWorkerImageName {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [String] $Key,
        [Parameter(Mandatory = $false)] [String] $Team
    )

    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module powershell-yaml -ErrorAction Stop

    $YAML = (Get-WorkerImageSource -Key $Key -Team $(if ($Team -ieq 'tceng') { 'tceng' }) -Provider GCP -RejectDev).Yaml

    if ($Team -and $Team -ieq "tceng") {
        $uuid = ([guid]::NewGuid().ToString('N')).Substring(0, 20)
        $ImageName = "imageset-$uuid"
        if ($env:GITHUB_ENV) {
            "PKR_VAR_uuid=$uuid" | Out-File -FilePath $env:GITHUB_ENV -Append
        }
    } else {
        if ($Key -notmatch "alpha") {
            $suffix = Get-Date -Format "yyyy-MM-dd"
            $ImageName = -join ($YAML.image["image_name"], "-", $suffix)
        } else {
            $ImageName = $YAML.image["image_name"]
        }
    }

    Write-Host "Setting $ImageName as the name for the worker image"
    if ($env:GITHUB_OUTPUT) {
        "IMAGENAME=$ImageName" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
    } else {
        Write-Output "IMAGENAME=$ImageName"
    }
}
