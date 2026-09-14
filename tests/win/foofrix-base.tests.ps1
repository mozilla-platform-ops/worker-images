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
