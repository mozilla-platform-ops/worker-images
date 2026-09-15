function Import-WorkerImagesYaml {
    if (-not (Get-Module -ListAvailable powershell-yaml)) {
        Install-Module powershell-yaml -Scope CurrentUser -Force -ErrorAction Stop
    }
    Import-Module powershell-yaml -ErrorAction Stop
}
