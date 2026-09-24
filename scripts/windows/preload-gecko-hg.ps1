$ErrorActionPreference = 'Stop'

if (-not $env:GECKO_HG_SEED_REVISION) {
    Write-Host 'Gecko Hg image seed is disabled'
    exit 0
}

$python = 'C:\mozilla-build\python3\python3.exe'
$hg = 'C:\Program Files\Mercurial\hg.exe'
$helper = 'C:\gecko_hg.py'
if ([Environment]::GetEnvironmentVariable('HG_CACHE', 'Machine') -ne 'C:\hg-cache') {
    throw 'Gecko Hg seeds require Puppet to set HG_CACHE to C:\hg-cache'
}
if (Get-Service worker-runner -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running') {
    throw 'Stop worker-runner before building the image seed'
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

if ($mode -eq 'windows-arm64') {
    & $python $helper install --seed-root $seed --destination-root 'C:\caches' `
        --state-file 'C:\worker-runner\directory-caches.json'
    if ($LASTEXITCODE -ne 0) { throw 'Gecko Hg cache registration failed' }
} else {
    # Puppet grants inherited task-user access to this shared store.
    # A temporary build directory can have a private ACL. Restore inheritance
    # on the new store, without removing Puppet's ACL on C:\hg-shared.
    Get-ChildItem -LiteralPath $seed -Directory | ForEach-Object {
        & icacls.exe $_.FullName /reset /T
        if ($LASTEXITCODE -ne 0) { throw 'Setting Hg store inheritance failed' }
    }
    & icacls.exe $seed /setowner '*S-1-5-18' /T
    if ($LASTEXITCODE -ne 0) { throw 'Setting the Hg store owner failed' }
}
