# Fetch a bake asset, picking the transport from the URL.
#
# Authenticated Azure blob (e.g. hardwareimaging - no anonymous access, an unauthenticated
# GET returns 409): azcopy with the build host's AAD login. azcopy has its own credential
# store and does NOT inherit `az login`, so AZCOPY_AUTO_LOGIN_TYPE drives OAuth (matches
# download-wim.ps1; azcopy 10.32 dropped --auth-mode on copy). Anything else is treated as
# a public URL (e.g. the roninpuppetassets prereq mirror).
function Get-BakeAsset {
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Destination
    )

    if ($Url -match '\.blob\.core\.windows\.net/') {
        if (-not $env:AZCOPY_AUTO_LOGIN_TYPE) { $env:AZCOPY_AUTO_LOGIN_TYPE = 'AZCLI' }
        & azcopy copy "$Url" "$Destination" --overwrite=true
        if ($LASTEXITCODE -ne 0) { throw "azcopy failed rc=$LASTEXITCODE for $Url" }
    }
    else {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    }
}

# Inject downloaded driver packs into an already mounted/applied Windows image.
function Add-OfflineDrivers {
    param(
        [Parameter(Mandatory)] [string] $ImagePath,
        [Parameter(Mandatory)] [string] $DriverCabUrls
    )
    $cabList = @($DriverCabUrls -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($cabList.Count -eq 0) { throw 'InjectDrivers set but -DriverCabUrls is empty.' }
    $drvRoot = Join-Path $env:TEMP ("winhwdrv-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $drvRoot -Force | Out-Null
    try {
        $n = 0
        foreach ($url in $cabList) {
            $n++
            $sub = Join-Path $drvRoot ("pkg{0:D2}" -f $n)
            New-Item -ItemType Directory -Path $sub -Force | Out-Null
            # Archive type from the URL path (ignore any ?query); name the temp file with
            # the right extension so Expand-Archive accepts it.
            $ext = [System.IO.Path]::GetExtension((($url -split '\?')[0])).ToLowerInvariant()
            if ($ext -notin '.cab', '.zip') { throw "Unsupported driver pack extension '$ext' for $url (expected .cab or .zip)." }
            $arc = Join-Path $sub ("pack" + $ext)
            Write-Host "== [$n/$($cabList.Count)] Downloading driver pack ($ext): $url =="
            Get-BakeAsset -Url $url -Destination $arc
            switch ($ext) {
                '.cab' {
                    Write-Host "== Expanding cab -> $sub =="
                    & expand.exe -F:* "$arc" "$sub" | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "expand.exe failed rc=$LASTEXITCODE for $url" }
                }
                '.zip' {
                    Write-Host "== Extracting zip -> $sub =="
                    Expand-Archive -LiteralPath $arc -DestinationPath $sub -Force
                }
            }
            Remove-Item $arc -Force
        }
        if (-not (Get-ChildItem -LiteralPath $drvRoot -Filter '*.inf' -Recurse -File)) { throw 'Driver packs contain no INF files.' }
        Write-Host "== DISM /Add-Driver (recurse) -> $ImagePath from $($cabList.Count) pack(s) =="
        & dism.exe /Image:"$ImagePath" /Add-Driver /Driver:"$drvRoot" /Recurse
        if ($LASTEXITCODE -ne 0) { throw "DISM /Add-Driver failed rc=$LASTEXITCODE" }
    }
    finally { Remove-Item -LiteralPath $drvRoot -Recurse -Force }
}
