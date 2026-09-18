# Offline check of the actual guest downloader, including retries and tampering.
$ErrorActionPreference = 'Stop'
$downloadTest = @{ requests = 0; payload = '' }
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('foofrix-download-' + [guid]::NewGuid())
New-Item -ItemType Directory $scratch | Out-Null
function Start-Sleep { param ($Seconds) }
function Invoke-RestMethod {
    param ($Uri, $Headers, $TimeoutSec)
    if ($Uri -notlike '*resource=https%3A%2F%2Fstorage.azure.com%2F&mi_res_id=%2Ftest-identity' -or $Headers.Metadata -ne 'true') {
        throw 'Incorrect managed identity request'
    }
    return @{ access_token = 'test-token' }
}
function Invoke-WebRequest {
    param ($Uri, $Headers, $OutFile, $TimeoutSec, [switch] $UseBasicParsing)
    $downloadTest.requests++
    if ($Uri -ne 'https://teststorage.blob.core.windows.net/artifacts/windows/installers/test/tool.exe' -or
        $Headers.Authorization -ne 'Bearer test-token' -or $Headers['x-ms-version'] -ne '2021-12-02') {
        throw 'Incorrect blob request'
    }
    if ($downloadTest.requests -eq 1) { throw 'Transient download failure' }
    [IO.File]::WriteAllText($OutFile, $downloadTest.payload)
}
try {
    $source = Join-Path $scratch 'source'
    [IO.File]::WriteAllText($source, 'verified installer')
    $manifest = Join-Path $scratch 'manifest.json'
    @{ prefix = 'windows/installers/test'; files = @(@{ name = 'tool.exe'; sha256 = (Get-FileHash $source).Hash }) } |
        ConvertTo-Json -Depth 4 | Set-Content $manifest
    $destination = Join-Path $scratch 'installers'
    $downloadTest.requests = 0
    $downloadTest.payload = 'verified installer'
    & ./scripts/windows/foofrix/download-installers.ps1 -StorageAccount teststorage -BuildIdentityId /test-identity -ManifestPath $manifest -Destination $destination
    if ($downloadTest.requests -ne 2 -or (Get-Content (Join-Path $destination 'tool.exe')) -ne $downloadTest.payload) { throw 'Retry/download failed' }
    Remove-Item (Join-Path $destination 'tool.exe')
    $downloadTest.payload = 'tampered installer'
    $downloadTest.requests = 0
    $failed = $false
    try {
        & ./scripts/windows/foofrix/download-installers.ps1 -StorageAccount teststorage -BuildIdentityId /test-identity -ManifestPath $manifest -Destination $destination
    } catch { $failed = $true }
    if (-not $failed -or $downloadTest.requests -ne 3 -or @(Get-ChildItem $destination).Count -ne 0) {
        throw 'Corrupt installer accepted, retry bound exceeded, or partial file retained'
    }
    Write-Host 'Guest download, retry, SHA-256 rejection, and cleanup checks passed.'
} finally { Remove-Item -LiteralPath $scratch -Recurse -Force }
