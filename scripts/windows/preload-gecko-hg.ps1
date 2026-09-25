$ErrorActionPreference = 'Stop'

if (-not $env:GECKO_HG_SEED_REVISION) {
    if ($env:GECKO_GIT_SEED_REVISION) { throw 'Git seeding requires the paired autoland Hg revision' }
    Write-Host 'Gecko Hg image seed is disabled'
    exit 0
}

$python = 'C:\mozilla-build\python3\python3.exe'
$hg = 'C:\Program Files\Mercurial\hg.exe'
$helper = 'C:\gecko_hg.py'
if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') {
    throw 'Build image seeds as SYSTEM so new cache files have the correct owner'
}
if ([Environment]::GetEnvironmentVariable('HG_CACHE', 'Machine') -ne 'C:\hg-cache') {
    throw 'Gecko Hg seeds require Puppet to set HG_CACHE to C:\hg-cache'
}
if (Get-Service worker-runner -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running') {
    throw 'Stop worker-runner before building the image seed'
}
if ($env:GECKO_GIT_SEED_REVISION -and (Test-Path -LiteralPath 'C:\worker-runner\directory-caches.json')) {
    throw 'Build the Git seed on a fresh image without Generic Worker cache state'
}

$mode = 'windows-x64'
$seed = 'C:\hg-shared'
if (@(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop).Architecture -contains 12) {
    $mode = 'windows-arm64'
    $seed = 'C:\gecko-hg-seed'
    if (Test-Path -LiteralPath 'C:\worker-runner\directory-caches.json') {
        throw 'Build the seed on a fresh image without Generic Worker cache state'
    }
}
if ((Test-Path -LiteralPath $seed) -and (Get-ChildItem -LiteralPath $seed -Force)) {
    throw "Seed directory must be empty: $seed"
}
& $python $helper build --revision $env:GECKO_HG_SEED_REVISION `
    --mode $mode --level $env:GECKO_HG_SEED_LEVEL --seed-root $seed --hg $hg
if ($LASTEXITCODE -ne 0) { throw 'Gecko Hg seed build failed' }
if ($mode -eq 'windows-x64') {
    # Check files made by both Hg and Python. Do not walk the full store.
    Get-ChildItem -LiteralPath $seed -Directory | ForEach-Object {
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

$extraSeed = @()
if ($env:GECKO_GIT_SEED_REVISION) {
    & $python $helper build-git --revision $env:GECKO_GIT_SEED_REVISION `
        --decision $env:GECKO_SEED_DECISION --mode $mode --level $env:GECKO_HG_SEED_LEVEL `
        --seed-root 'C:\gecko-git-seed' --git 'C:\Program Files\Git\cmd\git.exe'
    if ($LASTEXITCODE -ne 0) { throw 'Gecko Git seed build failed' }
    $extraSeed = @('--extra-seed-root', 'C:\gecko-git-seed')
}
if ($mode -eq 'windows-arm64') {
    & $python $helper install --seed-root $seed @extraSeed --destination-root 'C:\caches' `
        --state-file 'C:\worker-runner\directory-caches.json'
    if ($LASTEXITCODE -ne 0) { throw 'Gecko Hg cache registration failed' }
} else {
    if ($env:GECKO_GIT_SEED_REVISION) {
        & $python $helper install --seed-root 'C:\gecko-git-seed' --destination-root 'C:\caches' `
            --state-file 'C:\worker-runner\directory-caches.json'
        if ($LASTEXITCODE -ne 0) { throw 'Gecko Git cache registration failed' }
    }
}
