$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../scripts/windows/CustomFunctions/Bootstrap/Private/GeckoCacheSeed.ps1"

function Assert($Condition, $Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Throws($Action) {
    try { & $Action }
    catch { return }
    throw 'Expected operation to fail'
}

$hg = (Get-Command hg -ErrorAction Stop).Source
$git = (Get-Command git -ErrorAction Stop).Source
$env:HGPLAIN = '1'
$env:HGRCPATH = '/dev/null'
if ($env:OS -eq 'Windows_NT') { $env:HGRCPATH = 'NUL' }
$env:GIT_CONFIG_NOSYSTEM = '1'
$env:GIT_CONFIG_GLOBAL = $env:HGRCPATH
$env:GIT_TERMINAL_PROMPT = '0'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('windows-cache-test-' + [guid]::NewGuid())
$null = New-Item -ItemType Directory -Path $temp
try {
    $extension = $env:ROBUSTCHECKOUT
    if (-not $extension) {
        $extension = Join-Path $temp 'robustcheckout.py'
        Invoke-WebRequest -UseBasicParsing -Uri 'https://hg.mozilla.org/integration/autoland/raw-file/6978ac4b671864859416a7e5487211832eba1498/taskcluster/scripts/robustcheckout.py' -OutFile $extension
    }
    $source = Join-Path $temp 'hg-source'
    Invoke-SeedHg init $source
    [IO.File]::WriteAllText("$source/tracked", 'first')
    [IO.File]::WriteAllText("$source/profile", "[include]`ntracked`n")
    Invoke-SeedHg -R $source add | Out-Host
    Invoke-SeedHg -R $source commit -u test -m first
    $revision = Invoke-SeedHg -R $source log -r . -T '{node}'
    $upstream = Join-Path $temp 'upstream'
    Invoke-SeedHg clone $source $upstream | Out-Host
    Invoke-SeedHg -R $upstream branch other-project | Out-Host
    [IO.File]::WriteAllText("$upstream/tracked", 'upstream-only')
    Invoke-SeedHg -R $upstream commit -u test -m upstream
    $upstreamRevision = Invoke-SeedHg -R $upstream log -r . -T '{node}'
    $pool = Join-Path $temp 'seed/hg-store'
    New-HgSeed $revision $pool $extension $source $upstream
    Assert ((Invoke-SeedHg -R "$pool/$revision" log -r $upstreamRevision -T '{node}') -eq $upstreamRevision) 'Upstream history was not seeded'
    Assert (-not (Test-Path "$pool/$revision/tracked")) 'Hg seed checked out source files'
    Assert (-not (Test-Path "$pool/$revision/.hg/sharedpath")) 'Hg seed depends on another store'
    Assert-Throws { New-HgSeed $revision $pool $extension $source $upstream }
    Assert-Throws { New-HgSeed 'tip' "$temp/invalid" $extension $source $upstream }
    Assert-Throws { New-HgSeed ('e' * 40) "$temp/missing-revision" $extension $source $upstream }

    $state = @{}
    $created = [DateTime]::UtcNow.ToString('o')
    $caches = Join-Path $temp 'caches'
    $names = @('gecko-level-1-checkouts', 'gecko-level-1-checkouts-sparse', 'relops-level-3-checkouts-sparse')
    foreach ($name in $names) { Add-SeedCache $name "$temp/seed" $caches $state $created }
    Assert-Throws { Add-SeedCache $names[0] "$temp/seed" $caches $state $created }
    Assert-Throws { Add-SeedCache '../invalid' "$temp/seed" $caches $state $created }
    Assert-Throws { Add-SeedCache 'gecko-level-3-checkouts' "$temp/missing" $caches $state $created }
    Assert (-not $state.Contains('gecko-level-3-checkouts')) 'Failed copy was registered'
    [IO.File]::WriteAllText("$source/tracked", 'later')
    Invoke-SeedHg -R $source commit -u test -m later
    $head = Invoke-SeedHg -R $source log -r . -T '{node}'
    foreach ($name in $names) {
        $sharebase = "$caches/$name/hg-store"
        $checkout = "$caches/$name/src"
        $sparse = @()
        if ($name -like '*-sparse') { $sparse = @('--sparseprofile', 'profile') }
        Invoke-SeedHg --config "extensions.robustcheckout=$extension" --config extensions.share= --config extensions.sparse= `
            robustcheckout --sharebase $sharebase --upstream $upstream --purge --revision $head @sparse $source $checkout | Out-Host
        Assert ((Get-Content "$checkout/tracked" -Raw) -eq 'later') 'Hg cache did not update'
        Assert ((Get-Content "$sharebase/$revision/.hg/worker-image-seed" -Raw).Trim() -eq $revision) 'Hg seed was not reused'
    }
    [IO.File]::WriteAllText("$caches/$($names[-1])/hg-store/$revision/.hg/worker-image-seed", 'changed')
    Assert ((Get-Content "$caches/$($names[0])/hg-store/$revision/.hg/worker-image-seed" -Raw).Trim() -eq $revision) 'Hg caches share mutable files'

    $gitSource = Join-Path $temp 'git-source'
    Invoke-SeedGit init $gitSource | Out-Host
    foreach ($value in @('first', 'second')) {
        [IO.File]::WriteAllText("$gitSource/tracked", $value)
        Invoke-SeedGit -C $gitSource add .
        Invoke-SeedGit -C $gitSource -c user.name=test -c user.email=test@example.com commit -m $value | Out-Host
    }
    $gitRevision = Invoke-SeedGit -C $gitSource rev-parse HEAD
    $full = Join-Path $temp 'git-full/src'
    $shallow = Join-Path $temp 'git-shallow/src'
    $gitUri = ([uri]::new($gitSource, [UriKind]::Absolute)).AbsoluteUri
    New-GitSeed $gitRevision $gitUri $full $shallow
    Assert-Throws { New-GitSeed 'tip' $gitUri "$temp/invalid-full" "$temp/invalid-shallow" }
    [IO.File]::WriteAllText("$gitSource/tracked", 'later')
    Invoke-SeedGit -C $gitSource -c user.name=test -c user.email=test@example.com commit -am later | Out-Host
    $gitHead = Invoke-SeedGit -C $gitSource rev-parse HEAD
    foreach ($kind in @('full', 'shallow')) {
        $name = 'gecko-level-1-checkouts-git'
        if ($kind -eq 'shallow') { $name += '-shallow' }
        Add-SeedCache $name "$temp/git-$kind" $caches $state $created
        $repo = "$caches/$name/src"
        Assert ((Test-Path "$repo/.git/shallow") -eq ($kind -eq 'shallow')) 'Wrong Git depth'
        Assert (-not (Test-Path "$repo/.git/objects/info/alternates")) 'Git seed uses alternates'
        Assert (-not (Test-Path "$repo/tracked")) 'Git seed checked out source files'
        Assert ((Invoke-SeedGit -C $repo remote get-url origin) -eq $gitUri) 'Wrong Git remote'
        Invoke-SeedGit -C $repo fetch origin $gitHead | Out-Host
        Invoke-SeedGit -C $repo checkout --detach $gitHead | Out-Host
        Assert ((Get-Content "$repo/tracked" -Raw) -eq 'later') 'Git cache did not update'
        Assert ((Get-Content "$repo/.git/worker-image-seed" -Raw).Trim() -eq $gitRevision) 'Git seed was not reused'
    }
    [IO.File]::WriteAllText("$caches/gecko-level-1-checkouts-git/src/.git/worker-image-seed", 'changed')
    Assert ((Get-Content "$caches/gecko-level-1-checkouts-git-shallow/src/.git/worker-image-seed" -Raw).Trim() -eq $gitRevision) 'Git caches share mutable files'
    $stateFile = Join-Path $temp 'state.json'
    Write-SeedState $state $stateFile
    $saved = Get-Content $stateFile -Raw
    $records = $saved | ConvertFrom-Json
    Assert (@($records.PSObject.Properties).Count -eq 5) 'Cache records were lost'
    Assert (([DateTime]$records.'gecko-level-1-checkouts'[0].created).ToUniversalTime() -eq ([DateTime]$created).ToUniversalTime()) 'Cache creation time was lost'
    Assert-Throws { Write-SeedState @{} $stateFile }
    Assert ((Get-Content $stateFile -Raw) -eq $saved) 'Live worker state was replaced'
    Write-Host 'Windows Hg/Git seed checks passed'
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
