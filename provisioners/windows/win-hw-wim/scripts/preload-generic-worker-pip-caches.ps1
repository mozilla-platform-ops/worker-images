$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$python = 'C:\mozilla-build\python3\python3.exe'
$seedRoot = 'C:\cache-seeds'
$cache = Join-Path $seedRoot 'gecko-level-3-pip'
$download = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))

# Seed one pure-Python wheel to check pip cache reuse on alpha workers.
if (-not (Test-Path -LiteralPath $python)) {
    throw "MozillaBuild Python is missing: $python"
}
New-Item -ItemType Directory -Path $seedRoot, $cache, $download -Force | Out-Null

try {
    & $python -m pip --isolated --disable-pip-version-check --cache-dir $cache download `
        --index-url https://pypi.org/simple --only-binary=:all: --no-deps `
        --dest $download six==1.17.0
    if ($LASTEXITCODE -ne 0) {
        throw "Preparing the pip cache failed: $LASTEXITCODE"
    }

    Copy-Item -LiteralPath $cache -Destination (Join-Path $seedRoot 'gecko-level-1-pip') -Recurse

    & icacls.exe $seedRoot /inheritance:r `
        /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' `
        /setowner '*S-1-5-18' /T /C
    if ($LASTEXITCODE -ne 0) {
        throw "Setting cache seed ACLs failed: $LASTEXITCODE"
    }
}
finally {
    Remove-Item -LiteralPath $download -Recurse -Force -ErrorAction SilentlyContinue
}
