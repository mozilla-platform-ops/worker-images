$script:ImageSources = @{}
$script:ActiveImageSource = $null

function Read-WorkerImageYaml {
    param([string] $Root, [string] $Path)
    # Configs and build inputs must not escape the selected checkout through links.
    $item = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
    foreach ($part in ($Path -split '/')) {
        if ($part -in @('', '.', '..') -or $part.Contains('\')) { throw "Invalid image path: $Path" }
        $item = Get-Item -LiteralPath (Join-Path $item.FullName $part) -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Not authorized: image config path contains a link: $Path"
        }
    }
    $yaml = ConvertFrom-Yaml (Get-Content -LiteralPath $item.FullName -Raw -ErrorAction Stop)
    if ($yaml -isnot [System.Collections.IDictionary]) { throw "Expected a YAML mapping in $Path" }
    if ($Path -match '^config/[^/]+/' -and $yaml.Contains('dev')) {
        throw 'Not authorized: dev branch selection is restricted to RelOps root-level alpha image configs; dev is not permitted in config subdirectories.'
    }
    return $yaml
}

function Assert-WorkerImageDev {
    param($Yaml, [string] $Key, [string] $Root)
    if (-not $Yaml.Contains('dev')) { return }
    try {
        $users = Get-Content -LiteralPath "$Root/.github/relsre.json" -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw 'Not authorized: trusted RelOps allowlist is unavailable.'
    }
    if (-not $env:GITHUB_ACTOR -or $users -notcontains $env:GITHUB_ACTOR -or
        ($env:GITHUB_TRIGGERING_ACTOR -and $users -notcontains $env:GITHUB_TRIGGERING_ACTOR)) {
        throw 'Not authorized: dev branch selection is restricted to the RelOps team.'
    }
    if ($Key -notmatch '-alpha2?$') { throw "dev is supported only for alpha images: $Key" }
    if ($Yaml.dev -isnot [string] -or [string]::IsNullOrWhiteSpace($Yaml.dev)) {
        throw "dev must be a nonempty worker-images branch name: $Key"
    }
}

function Assert-WorkerImageAlpha {
    param($Yaml, [string] $Provider)
    if ($Provider -eq 'Azure') {
        foreach ($name in @($Yaml.sharedimage.gallery_name, $Yaml.sharedimage.image_name, $Yaml.vm.tags.worker_pool_id)) {
            if ($name -notmatch '^[a-z0-9][a-z0-9_.-]*[-_]alpha2?$') { throw 'dev cannot target a non-alpha Azure gallery, image, or worker pool.' }
        }
    } elseif ($Yaml.image.image_name -notmatch '^[a-z][a-z0-9-]*-alpha2?$') {
        throw 'dev cannot target a non-alpha GCP image.'
    }
}

function Invoke-WorkerImageGit {
    param([string] $Root, [string[]] $Arguments)
    $result = & git -C $Root @Arguments
    if ($LASTEXITCODE -ne 0) { throw "worker-images git $($Arguments[0]) failed (exit $LASTEXITCODE)" }
    return $result
}

function Invoke-WorkerImageDevCommand {
    param(
        $Source,
        [ValidateSet('New-AzSharedWorkerImage', 'New-AzWorkerImage', 'New-GCPWorkerImage')][string] $Command,
        [System.Collections.IDictionary] $Parameters
    )
    $previous = Get-Location
    Push-Location $Source.Root -ErrorAction Stop
    try {
        $module = Import-Module "$($Source.Root)/bin/WorkerImages/WorkerImages.psm1" -PassThru -Scope Local -ErrorAction Stop
        # The trusted resolver has already checked this config; do not follow dev again.
        & $module { param($source) $script:ActiveImageSource = $source } $Source
        & $module { param($command, $parameters) & $command @parameters } $Command $Parameters
        if ($LASTEXITCODE -ne 0) {
            throw "packer build failed with exit code $LASTEXITCODE"
        }
        # Existing workflows publish artifacts from their original checkout.
        foreach ($pattern in @("$($Source.Key)*.md", "sboms/$($Source.Yaml.image.image_name).md")) {
            foreach ($file in @(Get-ChildItem -Path (Join-Path $Source.Root $pattern) -File -ErrorAction SilentlyContinue)) {
                $relative = [IO.Path]::GetRelativePath($Source.Root, $file.FullName)
                $destination = Join-Path $previous.Path $relative
                $null = New-Item -ItemType Directory -Path (Split-Path $destination) -Force -ErrorAction Stop
                Copy-Item -LiteralPath $file.FullName -Destination $destination -Force -ErrorAction Stop
            }
        }
    } finally {
        Pop-Location
    }
}
