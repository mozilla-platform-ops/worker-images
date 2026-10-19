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

    $source = Get-WorkerImageSource -Key $Key -Team $(if ($Team -ieq 'tceng') { 'tceng' }) -Provider GCP
    if ($source.Root -ne (Get-Location).Path) {
        Invoke-WorkerImageDevCommand -Source $source -Command 'Set-GCPWorkerImageProject' -Parameters $PSBoundParameters
        return
    }

    if ($Team -and $Team -ieq "tceng") {
        $YamlPath = "config/tceng/$Key.yaml"
    } else {
        $YamlPath = "config/$Key.yaml"
    }

    if (-not (Test-Path $YamlPath)) {
        throw "YAML file not found at: $YamlPath"
    }

    $YAML = ConvertFrom-Yaml (Get-Content $YamlPath -Raw)
    $Project = $YAML.image["project_id"]

    Write-Host "Setting $Project as the project for the worker image"

    if ($env:GITHUB_OUTPUT) {
        "PROJECT=$Project" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
    } else {
        Write-Output "PROJECT=$Project"
    }
}