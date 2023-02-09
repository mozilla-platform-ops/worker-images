Set-PSRepository PSGallery -InstallationPolicy Trusted
Install-Module powershell-yaml -ErrorAction Stop
$win11642009 = Convertfrom-Yaml (Get-Content "config/win11-64-2009.yaml" -raw)
$locations = ($win11642009.azure.locations | ConvertTo-Json -Compress)
Write-Output "LOCATIONS=$locations" >> ENV:GITHUB_OUTPUT
#Write-Host "::set-output name=matrix::$($win11642009.azure.locations | ConvertTo-Json -Compress))"