function Initialize-GeckoCacheSeed {
    $ErrorActionPreference = 'Stop'

    if (-not $env:GECKO_HG_SEED_REVISION) {
        if ($env:GECKO_GIT_SEED_REVISION) { throw 'Git seeding requires the paired autoland Hg revision' }
        Write-Host 'Gecko image seed is disabled'
        return
    }
    if ($env:GECKO_HG_SEED_REVISION -cnotmatch '^[0-9a-f]{40}$' -or
        $env:GECKO_HG_SEED_LEVEL -notin @('1', '3')) { throw 'Invalid Hg seed revision or cache level' }
    if ($env:GECKO_GIT_SEED_REVISION -and
        ($env:GECKO_GIT_SEED_REVISION -cnotmatch '^[0-9a-f]{40}$' -or
         $env:GECKO_SEED_DECISION -cnotmatch '^[A-Za-z0-9_-]{22}$')) { throw 'Invalid Git revision or decision task ID' }
    if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') {
        throw 'Build image seeds as SYSTEM so new cache files have the correct owner'
    }
    if ([Environment]::GetEnvironmentVariable('HG_CACHE', 'Machine') -ne 'C:\hg-cache') {
        throw 'Gecko Hg seeds require Puppet to set HG_CACHE to C:\hg-cache'
    }
    if (Get-Service worker-runner -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running') {
        throw 'Stop worker-runner before building the image seed'
    }
    $arm64 = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop).Architecture -contains 12
    $stateFile = 'C:\worker-runner\directory-caches.json'
    if (($arm64 -or $env:GECKO_GIT_SEED_REVISION) -and (Test-Path -LiteralPath $stateFile)) {
        throw 'Build seeds on a fresh image without Generic Worker cache state'
    }
    $hg = 'C:\Program Files\Mercurial\hg.exe'
    $git = 'C:\Program Files\Git\cmd\git.exe'
    $env:HGPLAIN = '1'
    $env:HGRCPATH = 'NUL'
    $env:GIT_CONFIG_NOSYSTEM = '1'
    $env:GIT_CONFIG_GLOBAL = 'NUL'
    $env:GIT_TERMINAL_PROMPT = '0'
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('.gecko-seed-' + [guid]::NewGuid())
    $null = New-Item -ItemType Directory -Path $temp
    try {
        $robustcheckout = Join-Path $temp 'robustcheckout.py'
        $source = 'https://hg.mozilla.org/integration/autoland'
        $null = Invoke-DownloadWithRetry -Url "$source/raw-file/$env:GECKO_HG_SEED_REVISION/taskcluster/scripts/robustcheckout.py" -Path $robustcheckout
        $sharebase = 'C:\hg-shared'
        if ($arm64) { $sharebase = Join-Path $temp 'hg-cache/hg-store' }
        New-HgSeed $env:GECKO_HG_SEED_REVISION $sharebase $robustcheckout $source 'https://hg.mozilla.org/mozilla-unified'

        $state = @{}
        $created = [DateTime]::UtcNow.ToString('o')
        $level = $env:GECKO_HG_SEED_LEVEL
        if ($arm64) {
            foreach ($name in @("gecko-level-$level-checkouts", "gecko-level-$level-checkouts-sparse", 'relops-level-3-checkouts-sparse')) {
                Add-SeedCache $name (Split-Path -Parent $sharebase) 'C:\caches' $state $created
            }
        }
        else {
            Get-ChildItem -LiteralPath $sharebase -Directory | ForEach-Object {
                foreach ($relative in @('.hg\store\00changelog.i', '.hg\worker-image-seed')) {
                    $acl = Get-Acl -LiteralPath (Join-Path $_.FullName $relative)
                    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne 'S-1-5-18') {
                        throw 'The Hg seed must be owned by SYSTEM'
                    }
                    $access = $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) |
                        Where-Object {
                            $_.IdentityReference.Value -eq 'S-1-1-0' -and $_.IsInherited -and
                            $_.AccessControlType -eq 'Allow' -and
                            ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq
                                [Security.AccessControl.FileSystemRights]::FullControl
                        }
                    if (-not $access) { throw 'The Hg seed did not inherit Puppet task-user access' }
                }
            }
        }
        if ($env:GECKO_GIT_SEED_REVISION) {
            $full = Join-Path $temp 'git-full/src'
            $shallow = Join-Path $temp 'git-shallow/src'
            New-GitSeed $env:GECKO_GIT_SEED_REVISION 'https://github.com/mozilla-firefox/firefox' $full $shallow
            Add-SeedCache "gecko-level-$level-checkouts-git" (Split-Path -Parent $full) 'C:\caches' $state $created
            Add-SeedCache "gecko-level-$level-checkouts-git-shallow" (Split-Path -Parent $shallow) 'C:\caches' $state $created
        }
        if ($state.Count) { Write-SeedState $state $stateFile }
    }
    finally {
        Remove-Item -LiteralPath $temp -Recurse -Force
    }
}
