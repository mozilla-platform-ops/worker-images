param(
    [Parameter(Mandatory)][string] $Key,
    [Parameter(Mandatory)][ValidateSet('Azure', 'GCP')][string] $Provider,
    [string] $Team,
    [string] $Revision = $env:WORKER_IMAGES_REVISION
)
$ErrorActionPreference = 'Stop'
Import-Module powershell-yaml
Import-Module "$PSScriptRoot/../bin/WorkerImages/WorkerImages.psm1" -Force
$source = Get-WorkerImageSource -Key $Key -Team $Team -Provider $Provider -Revision $Revision
$yaml = $source.Yaml
$metadata = [ordered]@{
    config = $Key
    revision = $source.Revision
    branch = $source.Branch
    IMAGENAME = $(if ($Provider -eq 'GCP') { $yaml.image.image_name } else { $yaml.sharedimage.image_name })
    PROJECT = $(if ($Provider -eq 'GCP') { $yaml.image.project_id } else { '' })
}
$metadata | ConvertTo-Json | Set-Content -LiteralPath "image-source-$Key.json"
foreach ($entry in $metadata.GetEnumerator()) {
    if ($env:GITHUB_OUTPUT) { "$($entry.Key)=$($entry.Value)" >> $env:GITHUB_OUTPUT }
}
if ($env:GITHUB_ENV) { "WORKER_IMAGES_REVISION=$($source.Revision)" >> $env:GITHUB_ENV }
