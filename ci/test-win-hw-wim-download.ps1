$ErrorActionPreference = 'Stop'
$download = Join-Path $PSScriptRoot '../provisioners/windows/win-hw-wim/scripts/download-wim.ps1'
$dir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
$script:requests = @()

function azcopy {
    $url = $args[1]
    $dest = $args[2]
    $script:requests += $url
    if ($url -like '*.sha256') {
        $hash = if ($script:tamper) { '0' * 64 } else {
            (Get-FileHash -LiteralPath $dest.Substring(0, $dest.Length - 7) -Algorithm SHA256).Hash
        }
        [IO.File]::WriteAllText($dest, "$hash  output.wim")
    }
    else {
        [IO.File]::WriteAllText($dest, 'test WIM')
    }
    $global:LASTEXITCODE = 0
}

try {
    New-Item -ItemType Directory -Path $dir | Out-Null
    . $download -Blob resources/WIMs/base.wim -Dest (Join-Path $dir 'base.wim') -SkipSidecar
    if ($script:requests.Count -ne 1 -or $script:requests[0] -notlike '*/resources/WIMs/base.wim') {
        throw 'Base WIM should download without requesting a sidecar.'
    }

    . $download -Blob captured/WIMs/output.wim -Dest (Join-Path $dir 'output.wim')
    if ($script:requests.Count -ne 3 -or $script:requests[2] -notlike '*.sha256') {
        throw 'Captured WIM should download and verify its sidecar.'
    }

    $script:tamper = $true
    $rejected = $false
    try { . $download -Blob captured/WIMs/bad.wim -Dest (Join-Path $dir 'bad.wim') }
    catch { $rejected = $_.Exception.Message -like '*SHA-256 mismatch*' }
    if (-not $rejected) { throw 'Captured WIM with a bad sidecar must be rejected.' }
}
finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
