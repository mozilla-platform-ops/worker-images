param(
    [Parameter(Mandatory)][string] $Key,
    [Parameter(Mandatory)][ValidateSet('Azure', 'GCP')][string] $Provider,
    [switch] $RejectDev
)
$ErrorActionPreference = 'Stop'
Import-Module powershell-yaml
Import-Module "$PSScriptRoot/../bin/WorkerImages/WorkerImages.psm1" -Force
$source = Get-WorkerImageSource -Key $Key -Provider $Provider -RejectDev:$RejectDev
if ($RejectDev) { return }
try {
    $yaml = $source.Yaml
    $metadata = [ordered]@{
        revision = $source.Revision
        IMAGENAME = $(if ($Provider -eq 'GCP') { $yaml.image.image_name } else { $yaml.sharedimage.image_name })
        PROJECT = $(if ($Provider -eq 'GCP') { $yaml.image.project_id } else { '' })
    }
    foreach ($entry in $metadata.GetEnumerator()) {
        if ($env:GITHUB_OUTPUT) { "$($entry.Key)=$($entry.Value)" >> $env:GITHUB_OUTPUT }
    }
    if ($env:GITHUB_ENV) { "WORKER_IMAGES_REVISION=$($source.Revision)" >> $env:GITHUB_ENV }
} finally {
    if ($source.Root -ne (Get-Location).Path) {
        & git worktree remove --force $source.Root
        if ($LASTEXITCODE -ne 0) { Write-Warning "Could not remove selection worktree '$($source.Root)'." }
    }
}
