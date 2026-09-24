Function Set-AzRoninRepo {
    param (
        [string] $ronin_repo = "$env:systemdrive\ronin",
        [string] $nodes_def_src = "$env:systemdrive\BootStrap\nodes.pp",
        [string] $nodes_def = "$env:systemdrive\ronin\manifests\nodes.pp",
        [string] $bootstrap_dir = "$env:systemdrive\BootStrap\",
        [string] $secret_src = "$env:systemdrive\BootStrap\secrets\",
        [string] $secrets = "$env:systemdrive\ronin\data\secrets\",
        [String] $sentry_reg = "HKLM:SYSTEM\CurrentControlSet\Services",
        [string] $workerType = (Get-ItemProperty "HKLM:\SOFTWARE\Mozilla\ronin_puppet").workerType,
        [string] $role = $env:base_image,
        [string] $sourceOrg = $ENV:src_organisation,
        [string] $sourceRepo = $ENV:src_Repository,
        [string] $sourceBranch = $ENV:src_Branch,
        [string] $deploymentId = $ENV:deploymentId
    )

    begin {
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Write-Log -message ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'
        Write-Host "========== $($MyInvocation.MyCommand.Name) started at $((Get-Date).ToUniversalTime().ToString('o')) =========="
    }
    process {
        if ([string]::IsNullOrWhiteSpace($deploymentId)) {
            Write-host ('{0} :: Unable to find deploymentID :: {1} or env var: {2}' -f $($MyInvocation.MyCommand.Name), $deploymentId, $ENV:deploymentId)
            exit 1
        }
        if (($deploymentId -ne 'NA') -and ($deploymentId -notmatch '^[0-9a-fA-F]{7,40}$')) {
            Write-Log -message ('{0} :: Invalid Ronin Puppet deployment ID {1}' -f $($MyInvocation.MyCommand.Name), $deploymentId) -severity 'ERROR'
            exit 1
        }
        if (Test-Path -LiteralPath $ronin_repo) {
            Remove-Item -LiteralPath $ronin_repo -Recurse -Force -ErrorAction Stop
        }
        do {
            git clone -q --single-branch --branch $sourceBranch "https://github.com/$sourceOrg/$sourceRepo" $ronin_repo
            $git_exit = $LastExitCode
            if ($git_exit -ne 0) {
                Write-Log -message  ('{0} :: Git clone failed! https://github.com/{1}/{2}. Branch: {3}.' -f $($MyInvocation.MyCommand.Name), ($sourceOrg), ($sourceRepo), ($sourceBranch)) -severity 'DEBUG'
                Remove-Item -LiteralPath $ronin_repo -Recurse -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 15
            }
        } until ($git_exit -eq 0)
        Write-Log -message ('{0} :: Cloned from https://github.com/{1}/{2}. Branch: {3}.' -f $($MyInvocation.MyCommand.Name), ($sourceOrg), ($sourceRepo), ($sourceBranch)) -severity 'DEBUG'
        Write-Host ('{0} :: Cloned from https://github.com/{1}/{2}. Branch: {3}.' -f $($MyInvocation.MyCommand.Name), $sourceOrg, $sourceRepo, $sourceBranch)
        Set-Location $ronin_repo
        if ($deploymentId -ne "NA") {
            git checkout -q $deploymentId
            if ($LastExitCode -ne 0) {
                Write-Log -message ('{0} :: Unable to check out Ronin Puppet deployment ID {1}' -f $($MyInvocation.MyCommand.Name), $deploymentId) -severity 'ERROR'
                exit 1
            }
        }
        $resolvedDeploymentId = "$(git rev-parse HEAD)".Trim()
        if (($LastExitCode -ne 0) -or ($resolvedDeploymentId -notmatch '^[0-9a-fA-F]{40}$')) {
            Write-Log -message ('{0} :: Unable to resolve Ronin Puppet HEAD' -f $($MyInvocation.MyCommand.Name)) -severity 'ERROR'
            exit 1
        }
        if (($deploymentId -ne 'NA') -and
            (-not $resolvedDeploymentId.StartsWith($deploymentId, [System.StringComparison]::OrdinalIgnoreCase))) {
            Write-Log -message ('{0} :: Ronin Puppet checkout does not match deployment ID {1}' -f $($MyInvocation.MyCommand.Name), $deploymentId) -severity 'ERROR'
            exit 1
        }
        Write-Log -message ('{0} :: Ronin Puppet HEAD is set to {1}' -f $($MyInvocation.MyCommand.Name), $resolvedDeploymentId) -severity 'DEBUG'
        Write-Host ('{0} :: Ronin Puppet HEAD is set to {1}' -f $($MyInvocation.MyCommand.Name), $resolvedDeploymentId)
        # SECURITY: Puppet executes this repository as SYSTEM.
        Protect-PrivilegedDirectory -Path $ronin_repo
        if (-not (Test-path $nodes_def)) {
            Copy-item -path $nodes_def_src -destination $nodes_def -force
            (Get-Content -path $nodes_def) -replace 'roles::role', "roles::$role" | Set-Content $nodes_def
        }
        #if (-not (Test-path $secrets)) {
        #    Copy-item -path $secret_src -destination $secrets -recurse -force
        #}
        # Start to disable Windows defender here
        #$caption = ((Get-WmiObject Win32_OperatingSystem).caption)
        #$caption = $caption.ToLower()
        #$os_caption = $caption -replace ' ', '_'
        #if (Test-IsWin10) {
        #    ## This didn't work in windows 11, permissions issue. Will only run on Windows 10.
        #    $null = Set-ItemProperty -Path "$sentry_reg\SecurityHealthService" -name "start" -Value '4' -Type Dword
        #}
        #if ($os_caption -notlike "*2012*") {
        #    $null = Set-ItemProperty -Path "$sentry_reg\sense" -name "start" -Value '4' -Type Dword
        #}
    }
    end {
        $stopwatch.Stop()
        $elapsedMinutes = [int][math]::Floor($stopwatch.Elapsed.TotalMinutes)
        $elapsedSeconds = $stopwatch.Elapsed.Seconds
        Write-Log -message ('{0} :: completed in {1} minutes, {2} seconds' -f $($MyInvocation.MyCommand.Name), $elapsedMinutes, $elapsedSeconds) -severity 'DEBUG'
        Write-Host "========== $($MyInvocation.MyCommand.Name) completed in $elapsedMinutes minutes, $elapsedSeconds seconds =========="
    }
}
