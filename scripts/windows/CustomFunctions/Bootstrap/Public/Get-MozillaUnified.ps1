function Get-MozillaUnified {
    [CmdletBinding()]
    param (
        [String]
        $WorkerPoolId = $ENV:worker_pool_id,

        [String]
        $CacheRoot = "C:\worker-runner\caches",

        [String]
        $WorkerRunnerPath = "C:\worker-runner",

        [String]
        $Repository = "https://hg.mozilla.org/mozilla-unified",

        [String]
        $Hg = "C:\Program Files\Mercurial\hg.exe",

        [String]
        $Branch = "autoland",

        [String]
        $SparseProfile = "build/sparse-profiles/profile-generate"
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Log -message ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    Write-Host "========== $($MyInvocation.MyCommand.Name) started at $((Get-Date).ToUniversalTime().ToString('o')) =========="

    try {
        if ([String]::IsNullOrWhiteSpace($WorkerPoolId)) {
            try {
                $WorkerPoolId = Get-WorkerPoolId
            }
            catch {
                $WorkerPoolId = ""
            }
        }

        ## Let's capture both a string and boolean
        if ($ENV:clone_mozilla_unified -match "false|False" -or $ENV:clone_mozilla_unified -eq $false) {
            Write-Log -message "Skipping clone due to $ENV:clone_mozilla_unified" -severity 'INFO'
            Write-Host ('{0} :: Skipping clone due to {1}' -f $($MyInvocation.MyCommand.Name), $ENV:clone_mozilla_unified)
            return
        }

        if ($WorkerPoolId -notmatch '^win11-a64-25h2-builder(-alpha)?$') {
            Write-Log -message "Skipping mozilla-unified cache for worker pool $WorkerPoolId" -severity 'INFO'
            Write-Host ('{0} :: Skipping mozilla-unified cache for worker pool {1}' -f $($MyInvocation.MyCommand.Name), $WorkerPoolId)
            return
        }

        $CacheName = "gecko-level-1-checkouts-sparse"
        $CachePath = Join-Path $CacheRoot $CacheName
        $ClonePath = Join-Path $CachePath "src"
        $ShareBase = Join-Path $CachePath "hg-store"
        $MetadataPath = Join-Path $WorkerRunnerPath "directory-caches.json"

        if (-Not (Test-Path $Hg)) {
            throw "Mercurial not found at $Hg"
        }

        if (-Not (Test-Path "C:\mozilla-build\robustcheckout.py")) {
            throw "robustcheckout.py not found in C:\mozilla-build"
        }

        foreach ($Path in @($CacheRoot, $CachePath, $WorkerRunnerPath)) {
            if (-Not (Test-Path $Path)) {
                New-Item -ItemType Directory -Path $Path -Force | Out-Null
            }

            $acl = Get-Acl $Path
            $permission = "Everyone", "FullControl", "Allow"
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule $permission
            $acl.SetAccessRule($rule)
            Set-Acl $Path $acl
            Write-Log -message "Successfully set permissions on $Path" -severity 'INFO'
        }

        if ((Test-Path $ClonePath) -and (Test-Path $ShareBase)) {
            Write-Log -message "Using existing mozilla-unified checkout cache at $CachePath" -severity 'INFO'
        }
        else {
            Write-Log -message "Starting mozilla-unified checkout cache at $CachePath" -severity 'INFO'

            $Splat = @{
                FilePath     = $Hg
                ArgumentList = @(
                    "robustcheckout",
                    "--sharebase",
                    $ShareBase,
                    "--purge",
                    "--config",
                    "extensions.robustcheckout=C:\\mozilla-build\\robustcheckout.py",
                    "--upstream",
                    $Repository,
                    "--sparseprofile",
                    $SparseProfile,
                    "--branch",
                    $Branch,
                    $Repository,
                    $ClonePath
                )
                Wait         = $true
                PassThru     = $true
                NoNewWindow  = $true
            }
            $hgProcess = Start-Process @Splat

            if ($hgProcess.ExitCode -ne 0) {
                throw "Failed to cache mozilla-unified. Exit code: $($hgProcess.ExitCode)"
            }

            Write-Log -message "Successfully cached mozilla-unified at $CachePath" -severity 'INFO'
        }

        $timestamp = (Get-Date).ToUniversalTime().ToString("o")
        $directoryCaches = [ordered]@{}
        $directoryCaches[$CacheName] = @(
            [ordered]@{
                created   = $timestamp
                location  = $CachePath
                hits      = 0
                key       = $CacheName
                sha256    = ""
                in_use    = $false
                last_used = $timestamp
            }
        )
        $json = $directoryCaches | ConvertTo-Json -Depth 5
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($MetadataPath, "$json`n", $utf8NoBom)
        Write-Log -message "Wrote generic-worker directory cache metadata to $MetadataPath" -severity 'INFO'
    }
    catch {
        Write-Log -message "Error caching mozilla-unified: $($_.Exception.Message)" -severity 'ERROR'
        throw
    }
    finally {
        $stopwatch.Stop()
        $elapsedMinutes = [int][math]::Floor($stopwatch.Elapsed.TotalMinutes)
        $elapsedSeconds = $stopwatch.Elapsed.Seconds
        Write-Log -message ('{0} :: completed in {1} minutes, {2} seconds' -f $($MyInvocation.MyCommand.Name), $elapsedMinutes, $elapsedSeconds) -severity 'DEBUG'
        Write-Host "========== $($MyInvocation.MyCommand.Name) completed in $elapsedMinutes minutes, $elapsedSeconds seconds =========="
    }
}
