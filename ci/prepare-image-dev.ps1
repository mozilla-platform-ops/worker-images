param(
    [Parameter(Mandatory)][string] $Branch,
    [Parameter(Mandatory)][string] $Key,
    [Parameter(Mandatory)][ValidateSet('Azure', 'GCP')][string] $Provider
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

# Run from the trusted main checkout, before checking out or executing branch code.
& "$PSScriptRoot/check-authorized-user.ps1"
if ($LASTEXITCODE -ne 0) { throw 'Not authorized: development builds are restricted to RelSRE.' }
if ($Key -notmatch '^[a-zA-Z0-9_-]+-alpha2?$' -or $Key -match 'trusted') {
    throw 'Not authorized: select a non-trusted root-level alpha image config.'
}
git check-ref-format "refs/heads/$Branch"
$remote = git ls-remote --exit-code --heads origin "refs/heads/$Branch"
$revision = ($remote -split "`t")[0]
if ($revision -notmatch '^[0-9a-f]{40}$') { throw 'Could not resolve the selected branch to one commit.' }
git fetch --no-tags --no-write-fetch-head origin $revision
$tree = git ls-tree -r $revision
if ($tree -match '^120000 ') { throw 'Not authorized: development build inputs must not contain symbolic links.' }

Import-Module "$PSScriptRoot/../bin/WorkerImages"
$yaml = ConvertFrom-Yaml ((git show "${revision}:config/$Key.yaml") -join "`n")
if ($yaml -isnot [System.Collections.IDictionary]) { throw 'Expected an image YAML mapping.' }
if ($Provider -eq 'Azure') {
    foreach ($name in @($yaml.sharedimage.gallery_name, $yaml.sharedimage.image_name, $yaml.vm.tags.worker_pool_id)) {
        if ($name -notmatch '^[a-z0-9][a-z0-9_.-]*[-_]alpha2?$') {
            throw 'Not authorized: development builds require alpha Azure galleries, images, and worker pools.'
        }
    }
    $version = $yaml.sharedimage.image_version
    if ($version -eq 'default') {
        $defaults = ConvertFrom-Yaml ((git show "${revision}:config/windows_production_defaults.yaml") -join "`n")
        $version = $defaults.sharedimage.image_version
    }
    if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'Expected a numeric Azure image version.' }
    $notes = "$Key-$version.md"
} else {
    if ($yaml.image.project_id -ne 'taskcluster-imaging' -or
        $yaml.image.image_name -notmatch '^[a-z][a-z0-9-]*-alpha2?$') {
        throw 'Not authorized: development builds require an alpha image in the non-trusted taskcluster-imaging GCP project.'
    }
    $notes = "sboms/$($yaml.image.image_name).md"
}
Write-Host "Development build: $Branch at $revision ($Key, $Provider)"
"revision=$revision", "notes=$notes" | Add-Content -LiteralPath $env:GITHUB_OUTPUT
