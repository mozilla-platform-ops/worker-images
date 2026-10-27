function Set-NetFx3 {
    [CmdletBinding()]
    param (
        [string] $cab = "Microsoft-Windows-NetFx3-OnDemand-Package~31bf3856ad364e35~amd64~~.cab",
        [string] $url = "https://roninpuppetassets.blob.core.windows.net/binaries/$cab",
        [string] $sha256 = "53470DC8BEC1F5343109732AAEB7655DC1988F5ED6967DD129ACDF9693E293BB",
        [string] $source = "$env:systemdrive\BootStrap\netfx3"
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Log -message ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    Write-Host "========== $($MyInvocation.MyCommand.Name) started at $((Get-Date).ToUniversalTime().ToString('o')) =========="
    trap {
        $stopwatch.Stop()
        $elapsedMinutes = [int][math]::Floor($stopwatch.Elapsed.TotalMinutes)
        $elapsedSeconds = $stopwatch.Elapsed.Seconds
        Write-Log -message ('{0} :: completed in {1} minutes, {2} seconds' -f $($MyInvocation.MyCommand.Name), $elapsedMinutes, $elapsedSeconds) -severity 'DEBUG'
        Write-Host "========== $($MyInvocation.MyCommand.Name) completed in $elapsedMinutes minutes, $elapsedSeconds seconds =========="
        throw $_
    }

    # Windows Server 2022 only: the cab is the build 20348 Features on Demand package.
    # Windows Update cannot serve NetFx3 for Catalog-only builds such as 20348.5773 (KB5134140),
    # so install it from our mirror before Puppet's NET-Framework-Core resource runs.
    $os = Get-CimInstance Win32_OperatingSystem
    if ($os.BuildNumber -ne "20348" -or $os.ProductType -eq 1 -or $env:PROCESSOR_ARCHITECTURE -ne "AMD64") {
        Write-Log -message ('{0} :: Not Windows Server 2022 x64, skipping' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'
    }
    elseif ((Get-WindowsOptionalFeature -Online -FeatureName NetFx3).State -eq "Enabled") {
        Write-Log -message ('{0} :: NetFx3 already enabled' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'
    }
    else {
        New-Item -ItemType Directory -Path $source -Force | Out-Null
        $path = Invoke-DownloadWithRetry -Url $url -Path (Join-Path $source $cab)
        $hash = (Get-FileHash -Path $path -Algorithm SHA256).Hash
        if ($hash -ne $sha256) {
            throw "NetFx3 cab hash mismatch: expected $sha256, got $hash"
        }
        dism.exe /online /enable-feature /featurename:NetFx3 /all /source:$source /limitaccess /norestart /quiet
        if ($LASTEXITCODE -notin 0, 3010) {
            throw "dism failed to enable NetFx3 with exit code $LASTEXITCODE"
        }
        Write-Log -message ('{0} :: Enabled NetFx3 from {1}' -f $($MyInvocation.MyCommand.Name), $url) -severity 'DEBUG'
    }

    $stopwatch.Stop()
    $elapsedMinutes = [int][math]::Floor($stopwatch.Elapsed.TotalMinutes)
    $elapsedSeconds = $stopwatch.Elapsed.Seconds
    Write-Log -message ('{0} :: completed in {1} minutes, {2} seconds' -f $($MyInvocation.MyCommand.Name), $elapsedMinutes, $elapsedSeconds) -severity 'DEBUG'
    Write-Host "========== $($MyInvocation.MyCommand.Name) completed in $elapsedMinutes minutes, $elapsedSeconds seconds =========="
}
