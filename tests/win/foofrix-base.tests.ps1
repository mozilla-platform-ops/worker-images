# Runs after the image build's restart, using the refreshed machine PATH.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

foreach ($tool in @('git.exe', 'node.exe', 'python.exe', 'cargo.exe', 'rustc.exe', 'samply.exe', 'searchfox-cli.exe', 'gcloud.cmd')) {
    Get-Command $tool -ErrorAction Stop | Out-Null
    & $tool --version
    if ($LASTEXITCODE -ne 0) { throw "$tool failed its version check" }
}
if ((& node.exe -p 'process.versions.node.split(".")[0]') -ne '24') {
    throw 'FooFrix requires Node.js 24'
}
foreach ($service in @('worker-runner', 'Generic Worker')) {
    if (Get-Service $service -ErrorAction SilentlyContinue) {
        throw "Standalone FooFrix image must not contain $service"
    }
}
if (-not (Test-Path 'C:\FooFrix\artifacts' -PathType Container)) {
    throw 'Artifact directory is missing'
}

foreach ($name in @('CARGO_HOME', 'RUSTUP_HOME')) {
    $value = [Environment]::GetEnvironmentVariable($name, 'Machine')
    if (-not $value.StartsWith('C:\FooFrix\')) { throw "$name must use a shared image path" }
}
# Compile and link a tiny program: a version check alone misses missing MSVC/SDK bits.
$source = Join-Path $env:TEMP 'foofrix-rust-check.rs'
$output = Join-Path $env:TEMP 'foofrix-rust-check.exe'
try {
    'fn main() { println!("foofrix"); }' | Set-Content $source
    & rustc.exe --crate-name foofrix_check $source -o $output
    if ($LASTEXITCODE -ne 0) { throw 'Rust/MSVC compile and link failed' }
    if ((& $output) -ne 'foofrix') { throw 'Compiled Rust program failed' }
} finally {
    Remove-Item $source, $output -Force -ErrorAction SilentlyContinue
}
if (-not (Test-Path 'C:\FooFrix\cargo-tools.txt')) { throw 'Tool inventory is missing' }

# Exercise the baked payload from the Packer account after the second restart.
foreach ($tool in @('foofrix.cmd', 'run-speedometer.cmd', 'profiler-cli.cmd', 'codex.cmd')) {
    & $tool --help
    if ($LASTEXITCODE -ne 0) { throw "$tool failed its help check" }
}
foreach ($path in @(
    'C:\FooFrix\source-manifest.json',
    'C:\FooFrix\npm-tools.json',
    'C:\FooFrix\tools\profiler\profiler-cli\dist\mappings.wasm',
    'C:\FooFrix\tools\run-speedometer\speedometer\index.html',
    'C:\FooFrix\src\firefox\obj-opt\dist\bin\firefox.exe',
    'C:\FooFrix\src\firefox\obj-opt\dist\bin\xul.pdb'
)) {
    if (-not (Test-Path $path -PathType Leaf)) { throw "Missing prebaked payload: $path" }
}
& 'C:\FooFrix\src\foofrix\vendor\perfcompare-new-stats\.venv\Scripts\python.exe' -c 'import numpy, requests, retry, scipy, tqdm'
if ($LASTEXITCODE -ne 0) { throw 'Statistical comparison dependencies failed to import' }

# Validate both projects' exact Playwright revisions from the shared browser cache.
foreach ($project in @('C:\FooFrix\src\foofrix', 'C:\FooFrix\tools\run-speedometer')) {
    & node.exe -e @'
const { firefox } = require(process.argv[1] + '/node_modules/playwright');
(async () => {
  const browser = await firefox.launch({ headless: true, timeout: 60000 });
  try {
    const page = await browser.newPage();
    await page.setContent('<title>foofrix-image</title>');
    if (await page.title() !== 'foofrix-image') throw Error('Browser smoke failed');
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
'@ $project
    if ($LASTEXITCODE -ne 0) { throw "Playwright browser launch failed for $project" }
}

# Stock Firefox lacks Playwright's protocol patches: smoke it directly instead.
$profile = Join-Path $env:TEMP ('foofrix-browser-' + [guid]::NewGuid())
$screenshot = Join-Path $profile 'smoke.png'
New-Item -ItemType Directory $profile | Out-Null
try {
    $browser = Start-Process $env:FIREFOX_BIN -ArgumentList "--headless --no-remote --profile `"$profile`" --screenshot `"$screenshot`" about:blank" -PassThru
    if (-not $browser.WaitForExit(60000)) {
        Stop-Process -Id $browser.Id -Force
        throw 'Prebuilt Firefox smoke test timed out'
    }
    if ($browser.ExitCode -ne 0 -or -not (Test-Path $screenshot)) { throw 'Prebuilt Firefox smoke test failed' }
} finally { Remove-Item $profile -Recurse -Force }
