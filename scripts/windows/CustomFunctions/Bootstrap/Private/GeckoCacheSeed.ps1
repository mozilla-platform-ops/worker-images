function Invoke-SeedGit {
    & $git @args
    if ($LASTEXITCODE -ne 0) { throw "Git seed command failed: $args" }
}

function New-GitSeed($Revision, $Source, $Full, $Shallow) {
    if ($Revision -cnotmatch '^[0-9a-f]{40}$') { throw 'Use a full Git revision' }
    if ((Test-Path -LiteralPath $Full) -or (Test-Path -LiteralPath $Shallow)) {
        throw 'Git seed directories must not exist'
    }
    Invoke-SeedGit init $Full | Out-Host
    Invoke-SeedGit -C $Full remote add origin $Source
    Invoke-SeedGit -C $Full fetch --progress --no-tags origin $Revision | Out-Host
    Invoke-SeedGit -C $Full update-ref HEAD $Revision
    # file:// forces local transport without alternates or hardlinked objects.
    $uri = ([uri]::new([IO.Path]::GetFullPath($Full), [UriKind]::Absolute)).AbsoluteUri
    Invoke-SeedGit clone --progress --no-checkout --no-hardlinks --depth=1 $uri $Shallow | Out-Host
    Invoke-SeedGit -C $Shallow remote set-url origin $Source
    foreach ($repo in @($Full, $Shallow)) {
        if ((Invoke-SeedGit -C $repo rev-parse --verify 'HEAD^{commit}') -cne $Revision) {
            throw 'The Git seed does not contain the selected revision at HEAD'
        }
        [IO.File]::WriteAllText("$repo/.git/worker-image-seed", "$Revision`n")
    }
}

function Add-SeedCache($Name, $Source, $Caches, $State, $Created) {
    if ($Name -cnotmatch '^(gecko-level-[13]-checkouts(?:-sparse|-git(?:-shallow)?)?|relops-level-3-checkouts-sparse)$') {
        throw "Invalid cache name: $Name"
    }
    $destination = Join-Path $Caches $Name
    if ($State.Contains($Name) -or (Test-Path -LiteralPath $destination)) {
        throw "Cache already exists: $Name"
    }
    $null = New-Item -ItemType Directory -Path $Caches -Force
    $pending = Join-Path $Caches ('.seed-' + [guid]::NewGuid())
    try {
        Copy-Item -LiteralPath $Source -Destination $pending -Recurse -Force
        [IO.Directory]::Move($pending, $destination)
    }
    finally {
        if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending -Recurse -Force }
    }
    $State[$Name] = @(@{ key = $Name; location = $destination; created = $Created })
}

function Write-SeedState($State, $StateFile) {
    $parent = Split-Path -Parent $StateFile
    $null = New-Item -ItemType Directory -Path $parent -Force
    $pending = Join-Path $parent ('.seed-state-' + [guid]::NewGuid())
    try {
        [IO.File]::WriteAllText($pending, ($State | ConvertTo-Json -Depth 5))
        # The two-argument Move refuses to replace existing worker state.
        [IO.File]::Move($pending, $StateFile)
    }
    finally {
        if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending -Force }
    }
}
