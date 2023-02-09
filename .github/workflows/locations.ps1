Set-PSRepository PSGallery -InstallationPolicy Trusted
Install-Module powershell-yaml -ErrorAction Stop
$win11642009 = Convertfrom-Yaml (Get-Content "config/win11-64-2009.yaml" -raw)
$locations = @()
$win11642009.azure.locations | ForEach-Object {
    $locations += @{
        location = $_
    }
}
Write-Host "::set-output name=matrix::$($locations | ConvertTo-JSON -Compress))"