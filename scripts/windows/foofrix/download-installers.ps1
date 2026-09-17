# Download inside the VM: large installer binaries must not cross WinRM.
param (
    [Parameter(Mandatory)] [ValidatePattern('^[a-z0-9]{3,24}$')] [string] $StorageAccount,
    [Parameter(Mandatory)] [string] $BuildIdentityId,
    [string] $ManifestPath = 'C:\FooFrix\installers.json',
    [string] $Destination = 'C:\FooFrix\artifacts\installers'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
if ($manifest.prefix -notmatch '^[a-zA-Z0-9_-]+(/[a-zA-Z0-9_-]+)*$') { throw 'Invalid installer prefix' }
New-Item -ItemType Directory -Path $Destination -Force | Out-Null
$identity = [Uri]::EscapeDataString($BuildIdentityId)
foreach ($file in $manifest.files) {
    if ($file.name -notmatch '^[a-zA-Z0-9_-][a-zA-Z0-9_.-]*$' -or $file.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw 'Invalid installer filename or SHA-256'
    }
    $path = Join-Path $Destination $file.name
    $partial = "$path.partial"
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Write-Host "Downloading $($file.name) (attempt $attempt/3)"
            $token = Invoke-RestMethod -TimeoutSec 30 -Headers @{ Metadata = 'true' } -Uri (
                'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01' +
                '&resource=https%3A%2F%2Fstorage.azure.com%2F&mi_res_id=' + $identity
            )
            Invoke-WebRequest -UseBasicParsing -TimeoutSec 300 -Uri (
                "https://$StorageAccount.blob.core.windows.net/artifacts/$($manifest.prefix)/$($file.name)"
            ) -Headers @{
                Authorization = "Bearer $($token.access_token)"
                'x-ms-version' = '2021-12-02'
            } -OutFile $partial
            if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $file.sha256) {
                throw "SHA-256 mismatch for $($file.name)"
            }
            Move-Item -LiteralPath $partial -Destination $path -Force
            Write-Host "Verified $($file.name)"
            break
        } catch {
            if ($attempt -eq 3) { throw }
            Start-Sleep -Seconds 5
        } finally {
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        }
    }
}
