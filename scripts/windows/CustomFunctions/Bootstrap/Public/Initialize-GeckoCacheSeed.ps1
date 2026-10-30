function Initialize-GeckoCacheSeed {
    $ErrorActionPreference = 'Stop'

    if (-not $env:GECKO_GIT_SEED_REVISION) {
        Write-Host 'Gecko image seed is disabled'
        return
    }
    if ($env:GECKO_GIT_SEED_REVISION -cnotmatch '^[0-9a-f]{40}$' -or
        $env:GECKO_SEED_DECISION -cnotmatch '^[A-Za-z0-9_-]{22}$' -or
        $env:GECKO_HG_SEED_LEVEL -notin @('1', '3')) { throw 'Invalid Git revision, decision task ID, or cache level' }
    if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') {
        throw 'Build image seeds as SYSTEM so new cache files have the correct owner'
    }
    if (Get-Service worker-runner -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running') {
        throw 'Stop worker-runner before building the image seed'
    }
    $stateFile = 'C:\worker-runner\directory-caches.json'
    if (Test-Path -LiteralPath $stateFile) {
        throw 'Build seeds on a fresh image without Generic Worker cache state'
    }
    $git = 'C:\Program Files\Git\cmd\git.exe'
    $env:GIT_CONFIG_NOSYSTEM = '1'
    $env:GIT_CONFIG_GLOBAL = 'NUL'
    $env:GIT_TERMINAL_PROMPT = '0'
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('.gecko-seed-' + [guid]::NewGuid())
    $null = New-Item -ItemType Directory -Path $temp
    try {
        $state = @{}
        $created = [DateTime]::UtcNow.ToString('o')
        $level = $env:GECKO_HG_SEED_LEVEL
        $full = Join-Path $temp 'git-full/src'
        $shallow = Join-Path $temp 'git-shallow/src'
        New-GitSeed $env:GECKO_GIT_SEED_REVISION 'https://github.com/mozilla-firefox/firefox' $full $shallow
        Add-SeedCache "gecko-level-$level-checkouts-git" (Split-Path -Parent $full) 'C:\caches' $state $created
        Add-SeedCache "gecko-level-$level-checkouts-git-shallow" (Split-Path -Parent $shallow) 'C:\caches' $state $created
        Write-SeedState $state $stateFile
    }
    finally {
        Remove-Item -LiteralPath $temp -Recurse -Force
    }
}
