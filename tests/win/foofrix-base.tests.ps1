# Runs after the image build's restart, using the refreshed machine PATH.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

foreach ($tool in @('git.exe', 'node.exe', 'python.exe')) {
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
