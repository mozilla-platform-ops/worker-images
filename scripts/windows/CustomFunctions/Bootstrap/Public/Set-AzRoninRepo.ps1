Function Set-AzRoninRepo {
    param (
        [string] $ronin_repo = "$env:systemdrive\ronin",
        [string] $nodes_def_src = "$env:systemdrive\BootStrap\nodes.pp",
        [string] $nodes_def = "$env:systemdrive\ronin\manifests\nodes.pp",
        [string] $role = $env:base_image,
        [string] $sourceOrg = $ENV:src_organisation,
        [string] $sourceRepo = $ENV:src_Repository,
        [string] $sourceBranch = $ENV:src_Branch,
        [string] $deploymentId = $ENV:deploymentId
    )

    if ($null -eq $deploymentId) {
        Write-host ('{0} :: Unable to find deploymentID :: {1} or env var: {2}' -f $($MyInvocation.MyCommand.Name), $deploymentId, $ENV:deploymentId)
        exit 1
    }
    If ( -Not (test-path $env:systemdrive\ronin)) {
        git clone -q --single-branch --branch $sourceBranch "https://github.com/$sourceOrg/$sourceRepo" $ronin_repo
        $git_exit = $LastExitCode
        if ($git_exit -eq 0) {
            Write-Log -message ('{0} :: Cloned from https://github.com/{1}/{2}. Branch: {3}.' -f $($MyInvocation.MyCommand.Name), ($sourceOrg), ($sourceRepo), ($sourceBranch)) -severity 'DEBUG'
            Write-Host ('{0} :: Cloned from https://github.com/{1}/{2}. Branch: {3}.' -f $($MyInvocation.MyCommand.Name), $sourceOrg, $sourceRepo, $sourceBranch)
        }
        else {
            Write-Log -message  ('{0} :: Git clone failed! https://github.com/{1}/{2}. Branch: {3}.' -f $($MyInvocation.MyCommand.Name), ($sourceOrg), ($sourceRepo), ($sourceBranch)) -severity 'DEBUG'
            DO {
                Start-Sleep -s 15
                Write-Log -message  ('{0} :: Git clone https://github.com/{1}/{2}. Branch: {3}.' -f $($MyInvocation.MyCommand.Name), ($sourceOrg), ($sourceRepo), ($sourceBranch)) -severity 'DEBUG'
                git clone -q --single-branch --branch $sourceBranch "https://github.com/$sourceOrg/$sourceRepo" $ronin_repo
                $git_exit = $LastExitCode
            } Until ( $git_exit -eq 0)
        }
        Set-Location $ronin_repo
        if ($deploymentId -ne "NA") {
            git checkout -q $deploymentId
        }
        Write-Log -message ('{0} :: Ronin Puppet HEAD is set to {1}' -f $($MyInvocation.MyCommand.Name), $deploymentID) -severity 'DEBUG'
        Write-Host ('{0} :: Ronin Puppet HEAD is set to {1}' -f $($MyInvocation.MyCommand.Name), $deploymentID)
    }
    if (-not (Test-path $nodes_def)) {
        Copy-item -path $nodes_def_src -destination $nodes_def -force
        (Get-Content -path $nodes_def) -replace 'roles::role', "roles::$role" | Set-Content $nodes_def
    }
}
