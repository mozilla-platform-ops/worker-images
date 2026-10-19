function Get-WorkerImageSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Key,
        [string] $Team,
        [ValidateSet('Azure', 'GCP', 'AWS')][string] $Provider,
        [string] $Revision = $env:WORKER_IMAGES_REVISION
    )

    if ($Key -notmatch '^[a-zA-Z0-9_-]+$' -or ($Team -and $Team -notmatch '^[a-zA-Z0-9_-]+$')) {
        throw 'Not authorized: image key and team must be names without paths.'
    }
    $root = (Get-Location).Path
    $path = if ($Team) { "config/$Team/$Key.yaml" } else { "config/$Key.yaml" }
    $yaml = Read-WorkerImageYaml -Root $root -Path $path
    if ($script:ActiveImageSource -and $script:ActiveImageSource.Root -eq $root -and
        $script:ActiveImageSource.Key -eq $Key -and -not $Team) {
        return $script:ActiveImageSource
    }
    Assert-WorkerImageDev -Yaml $yaml -Key $Key -Team $Team -Root $root
    if (-not $yaml.Contains('dev')) {
        return [pscustomobject]@{ Root = $root; Key = $Key; Revision = ''; Branch = ''; Yaml = $yaml }
    }
    if ($Provider -notin @('Azure', 'GCP')) { throw 'dev supports only Azure and GCP alpha builds.' }
    if (-not $script:ImageSources) { $script:ImageSources = @{} }
    $cacheKey = "$root/$Key/$Provider/$Revision"
    if ($script:ImageSources.ContainsKey($cacheKey)) { return $script:ImageSources[$cacheKey] }

    $branch = $yaml.dev
    $null = Invoke-WorkerImageGit $root @('check-ref-format', "refs/heads/$branch")
    if ($Revision) {
        if ($Revision -notmatch '^[0-9a-f]{40}$') { throw 'Invalid pinned worker-images revision.' }
        $ref = $Revision
    } else {
        $ref = "refs/heads/$branch"
    }
    $null = Invoke-WorkerImageGit $root @('fetch', '--no-tags', 'origin', $ref)
    $commit = (Invoke-WorkerImageGit $root @('rev-parse', '--verify', 'FETCH_HEAD^{commit}')).Trim()
    if ($Revision -and $commit -ne $Revision) { throw 'Fetched worker-images revision differs from the pin.' }
    $directory = Join-Path ([IO.Path]::GetTempPath()) ("worker-image-$Key-" + [guid]::NewGuid())
    $null = Invoke-WorkerImageGit $root @('worktree', 'add', '--detach', $directory, $commit)
    try {
        # Reject links anywhere in branch build inputs, before loading any branch code.
        $links = Invoke-WorkerImageGit $root @('ls-tree', '-r', $commit)
        if ($links -match '^120000 ') { throw 'Not authorized: dev checkout must not contain symbolic links.' }
        $selected = Read-WorkerImageYaml -Root $directory -Path $path
        Assert-WorkerImageDev -Yaml $selected -Key $Key -Root $root
        $required = @('bin/WorkerImages/WorkerImages.psm1', $(if ($Provider -eq 'Azure') { 'bin/WorkerImages/Public/New-AzWorkerImage.ps1' } else { 'bin/WorkerImages/Public/New-GCPWorkerImage.ps1' }))
        if ($Provider -eq 'Azure') {
            $defaults = Read-WorkerImageYaml $directory 'config/windows_production_defaults.yaml'
            if ($defaults.Contains('dev')) { throw 'dev must be set on an individual root-level alpha image, not defaults.' }
            foreach ($config in @($yaml, $selected)) {
                foreach ($name in @($config.sharedimage.gallery_name, $config.sharedimage.image_name, $config.vm.tags.worker_pool_id)) {
                    if ($name -notmatch '[-_]alpha2?$') { throw 'dev cannot target a non-alpha Azure gallery, image, or worker pool.' }
                }
            }
            $required += @('azure.pkr.hcl', 'bin/WorkerImages/Public/New-AzSharedWorkerImage.ps1',
                'scripts/windows/CustomFunctions/Bootstrap', 'tests/win')
        } else {
            foreach ($config in @($yaml, $selected)) {
                if ($config.image.image_name -notmatch '-alpha2?$') { throw 'dev cannot target a non-alpha GCP image.' }
            }
            if ($selected.image.project_id -ne $yaml.image.project_id) {
                throw 'Not authorized: dev cannot change the GCP project or cloud identity.'
            }
            $required += @('gcp.pkr.hcl', 'scripts/linux', 'tests/linux')
        }
        foreach ($file in $required) {
            if (-not (Test-Path -LiteralPath (Join-Path $directory $file))) { throw "Missing dev build input: $file" }
        }
        $source = [pscustomobject]@{ Root = $directory; Key = $Key; Revision = $commit; Branch = $branch; Yaml = $selected }
        $script:ImageSources[$cacheKey] = $source
        Write-Host "worker-images $Key dev branch '$branch' pinned to $commit ($directory)"
        return $source
    } catch {
        $null = Invoke-WorkerImageGit $root @('worktree', 'remove', '--force', $directory)
        throw
    }
}
