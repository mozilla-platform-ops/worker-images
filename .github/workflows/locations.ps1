Set-PSRepository PSGallery -InstallationPolicy Trusted
Install-Module powershell-yaml -ErrorAction Stop
$win11642009 = Convertfrom-Yaml (Get-Content "config/win11-64-2009.yaml" -raw)
Write-Host "::set-output name=matrix::$($win11642009.azure.locations | ConvertTo-Json -Compress))"