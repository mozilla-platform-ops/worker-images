function Get-WorkerImageSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Key,
        [string] $Team,
        [ValidateSet('Azure', 'GCP')][string] $Provider,
        [string] $Revision = $env:WORKER_IMAGES_REVISION,
        [switch] $RejectDev
    )

    if ($Key -notmatch '^[a-zA-Z0-9_-]+$' -or ($Team -and $Team -notmatch '^[a-zA-Z0-9_-]+$')) {
        throw 'Not authorized: image key and team must be names without paths.'
    }
    $root = (Get-Location).Path
    $path = if ($Team) { "config/$Team/$Key.yaml" } else { "config/$Key.yaml" }
    $yaml = Read-WorkerImageYaml -Root $root -Path $path
    if ($RejectDev -and $yaml.Contains('dev')) { throw 'dev branch selection is not supported by this entry point. Use a supported single-image build.' }
    if ($script:ActiveImageSource -and $script:ActiveImageSource.Root -eq $root -and
        $script:ActiveImageSource.Key -eq $Key -and -not $Team) {
        return $script:ActiveImageSource
    }
    Assert-WorkerImageDev -Yaml $yaml -Key $Key -Root $root
    if (-not $yaml.Contains('dev')) {
        return [pscustomobject]@{ Root = $root; Key = $Key; Revision = ''; Branch = ''; Yaml = $yaml }
    }
    if ($Provider -notin @('Azure', 'GCP')) { throw 'dev supports only Azure and GCP alpha builds.' }
    Assert-WorkerImageAlpha -Yaml $yaml -Provider $Provider
    if (-not $script:ImageSources) { $script:ImageSources = @{} }
    $cacheKey = "$root/$Key/$Provider/$Revision"
    if ($script:ImageSources.ContainsKey($cacheKey)) { return $script:ImageSources[$cacheKey] }

    $branch = $yaml.dev
    $null = Invoke-WorkerImageGit $root @('check-ref-format', "refs/heads/$branch")
    if ($Revision) {
        $commit = $Revision
    } else {
        try {
            $remote = Invoke-WorkerImageGit $root @('ls-remote', '--exit-code', '--heads', 'origin', "refs/heads/$branch")
        } catch {
            throw "Could not resolve worker-images dev branch '$branch': $_"
        }
        $commit = ($remote -split "`t")[0]
    }
    if ($commit -notmatch '^[0-9a-f]{40}$') { throw 'Invalid pinned worker-images revision.' }
    # Fetch the immutable object without sharing FETCH_HEAD between image selections.
    $null = Invoke-WorkerImageGit $root @('fetch', '--no-tags', '--no-write-fetch-head', 'origin', $commit)
    $resolved = (Invoke-WorkerImageGit $root @('rev-parse', '--verify', "$commit^{commit}")).Trim()
    if ($resolved -ne $commit) { throw 'Fetched worker-images revision differs from the pin.' }
    $directory = Join-Path ([IO.Path]::GetTempPath()) ("worker-image-$Key-" + [guid]::NewGuid())
    $null = Invoke-WorkerImageGit $root @('worktree', 'add', '--detach', $directory, $commit)
    try {
        # Reject links anywhere in branch build inputs, before loading any branch code.
        $links = Invoke-WorkerImageGit $root @('ls-tree', '-r', $commit)
        if ($links -match '^120000 ') { throw 'Not authorized: dev checkout must not contain symbolic links.' }
        $selected = Read-WorkerImageYaml -Root $directory -Path $path
        Assert-WorkerImageDev -Yaml $selected -Key $Key -Root $root
        Assert-WorkerImageAlpha -Yaml $selected -Provider $Provider
        $required = @('bin/WorkerImages/WorkerImages.psm1', $(if ($Provider -eq 'Azure') { 'bin/WorkerImages/Public/New-AzWorkerImage.ps1' } else { 'bin/WorkerImages/Public/New-GCPWorkerImage.ps1' }))
        if ($Provider -eq 'Azure') {
            $defaults = Read-WorkerImageYaml $directory 'config/windows_production_defaults.yaml'
            if ($defaults.Contains('dev')) { throw 'dev must be set on an individual root-level alpha image, not defaults.' }
            $required += @('azure.pkr.hcl', 'bin/WorkerImages/Public/New-AzSharedWorkerImage.ps1',
                'scripts/windows/CustomFunctions/Bootstrap', 'tests/win')
        } else {
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
        $failure = $_
        try {
            $null = Invoke-WorkerImageGit $root @('worktree', 'remove', '--force', $directory)
        } catch {
            Write-Warning "Could not remove dev worktree '$directory': $_"
        }
        throw $failure
    }
}
