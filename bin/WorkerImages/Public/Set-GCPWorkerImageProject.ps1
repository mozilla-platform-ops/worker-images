function Set-GCPWorkerImageProject {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [String] $Key,
        [Parameter(Mandatory = $false)]
        [String] $Team
    )

    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module powershell-yaml -ErrorAction Stop

    $YAML = (Get-WorkerImageSource -Key $Key -Team $(if ($Team -ieq 'tceng') { 'tceng' }) -Provider GCP -RejectDev).Yaml
    $Project = $YAML.image["project_id"]

    Write-Host "Setting $Project as the project for the worker image"

    if ($env:GITHUB_OUTPUT) {
        "PROJECT=$Project" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
    } else {
        Write-Output "PROJECT=$Project"
    }
}