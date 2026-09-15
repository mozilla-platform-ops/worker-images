# Image-only setup. Runtime job selection and authentication happen after boot.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/bootstrap-helpers.ps1"

$shared = @{
    MOZILLABUILD = 'C:\mozilla-build\'
    MOZBUILD_STATE_PATH = 'C:\FooFrix\mozbuild'
    PLAYWRIGHT_BROWSERS_PATH = 'C:\FooFrix\playwright'
    NPM_CONFIG_PREFIX = 'C:\FooFrix\npm'
    FOOFRIX_TOOLS_DIR = 'C:\FooFrix\tools'
    FIREFOX_DIR = 'C:\FooFrix\src\firefox'
    FIREFOX_BIN = 'C:\FooFrix\src\firefox\obj-opt\dist\bin\firefox.exe'
    RUN_SPEEDOMETER_DIR = 'C:\FooFrix\tools\run-speedometer'
}
foreach ($name in $shared.Keys) {
    [Environment]::SetEnvironmentVariable($name, $shared[$name], 'Machine')
    [Environment]::SetEnvironmentVariable($name, $shared[$name], 'Process')
}
foreach ($directory in @($env:MOZBUILD_STATE_PATH, $env:PLAYWRIGHT_BROWSERS_PATH, $env:NPM_CONFIG_PREFIX)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$env:Path = "$machinePath;C:\FooFrix\npm;C:\mozilla-build\bin"
[Environment]::SetEnvironmentVariable('Path', $env:Path, 'Machine')
$env:GIT_TERMINAL_PROMPT = '0'
$env:HUSKY = '0'

# Pin public checkouts. Record the private bundle's revision in the same manifest.
$repositories = @(
    @{ name = 'firefox'; path = $env:FIREFOX_DIR; url = 'https://github.com/mozilla-firefox/firefox.git'; revision = '6c74efe2fcddf84b6f320959064a66946b4a1759' },
    @{ name = 'run-speedometer'; path = $env:RUN_SPEEDOMETER_DIR; url = 'https://github.com/dpalmeiro/run-speedometer.git'; revision = '54d8a591cf3131ad0c380f04fc4894c65fc0f2b9' },
    @{ name = 'profiler'; path = 'C:\FooFrix\tools\profiler'; url = 'https://github.com/firefox-devtools/profiler.git'; revision = '777fb266152bfc0d118c2e793839a8f5d72fe273' }
)
Invoke-BuildCommand git.exe @('config', '--system', 'core.longpaths', 'true')
foreach ($repo in $repositories) {
    Invoke-BuildCommand git.exe @('init', $repo.path)
    Invoke-BuildCommand git.exe @('-C', $repo.path, 'remote', 'add', 'origin', $repo.url)
    Invoke-BuildCommand git.exe @('-C', $repo.path, 'fetch', '--depth=1', 'origin', $repo.revision)
    Invoke-BuildCommand git.exe @('-C', $repo.path, 'checkout', '--detach', 'FETCH_HEAD')
}
$foofrix = 'C:\FooFrix\src\foofrix'
Invoke-BuildCommand git.exe @('clone', 'C:\FooFrix\artifacts\foofrix.bundle', $foofrix)
Invoke-BuildCommand git.exe @('-C', $foofrix, 'remote', 'set-url', 'origin', 'https://github.com/dpalmeiro/foofrix.git')
$revision = Invoke-BuildCommand git.exe @('-C', $foofrix, 'rev-parse', 'HEAD')
$repositories += @{ name = 'foofrix'; path = $foofrix; revision = "$revision" }
foreach ($repo in $repositories) {
    # The runtime account differs from SYSTEM; trust only these image-owned trees.
    Invoke-BuildCommand git.exe @('config', '--system', '--add', 'safe.directory', ($repo.path -replace '\\', '/'))
}

# Compile TS directly: upstream npm build also runs Unix-only chmod.
foreach ($project in @($foofrix, $env:RUN_SPEEDOMETER_DIR)) {
    Push-Location $project
    try {
        Invoke-BuildCommand git.exe @('submodule', 'update', '--init', '--recursive')
        Invoke-BuildCommand npm.cmd @('ci')
        Invoke-BuildCommand node.exe @('node_modules/typescript/bin/tsc')
        Invoke-BuildCommand npm.cmd @('link')
        Invoke-BuildCommand node.exe @('node_modules/playwright/cli.js', 'install', 'firefox')
    } finally { Pop-Location }
}

# Reuse the harness setup after explicitly creating its Windows venv with python.exe.
$venv = "$foofrix\vendor\perfcompare-new-stats\.venv"
Invoke-BuildCommand python.exe @('-m', 'venv', $venv)
Invoke-BuildCommand node.exe @("$foofrix\scripts\setup-perfcompare.mjs")
Invoke-BuildCommand npm.cmd @('install', '--global', 'yarn@1.22.22', '@openai/codex')
Push-Location 'C:\FooFrix\tools\profiler'
try {
    Invoke-BuildCommand yarn.cmd @('install', '--frozen-lockfile')
    Invoke-BuildCommand yarn.cmd @('build-cli')
} finally { Pop-Location }
foreach ($name in @('profiler-cli', 'pq')) {
    '@echo off', 'node "C:\FooFrix\tools\profiler\profiler-cli\dist\profiler-cli.js" %*' |
        Set-Content "C:\FooFrix\npm\$name.cmd" -Encoding ASCII
}

# A full native build, not an artifact build: retain source, objects, PDBs and mach caches.
Copy-Item "$PSScriptRoot/firefox.mozconfig" "$env:FIREFOX_DIR\mozconfig"
Push-Location $env:FIREFOX_DIR
try {
    Invoke-BuildCommand python.exe @('mach', '--no-interactive', 'bootstrap', '--application-choice=browser')
    Invoke-BuildCommand python.exe @('mach', '--no-interactive', 'build')
} finally { Pop-Location }
$repositories | ConvertTo-Json -Depth 3 | Set-Content 'C:\FooFrix\source-manifest.json'
Invoke-BuildCommand npm.cmd @('list', '--global', '--json') | Set-Content 'C:\FooFrix\npm-tools.json'
