function Get-MozillaUnified {
    [CmdletBinding()]
    param (
        [String]
        $ClonePath = "C:\vcs-checkout",

        [String]
        $Repository = "https://hg.mozilla.org/mozilla-unified",

        [String]
        $Hg = "C:\Program Files\Mercurial\hg.exe",

        [String]
        $Branch = "autoland"
    )
    ## Let's capture both a string and boolean
    if ($ENV:clone_mozilla_unified -match "false|False" -or $ENV:clone_mozilla_unified -eq $false) {
        Write-Log -message "Skipping clone due to $ENV:clone_mozilla_unified" -severity 'INFO'
        Write-Host ('{0} :: Skipping clone due to {1}' -f $($MyInvocation.MyCommand.Name), $ENV:clone_mozilla_unified)
        exit 0
    }

    ## Create directory and set permissions to everyone
    if (-Not (Test-Path $ClonePath)) {
        try {
            New-Item -ItemType Directory -Path $ClonePath -Force | Out-Null
            $acl = Get-Acl $ClonePath
            $permission = "Everyone", "FullControl", "Allow"
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule $permission
            $acl.SetAccessRule($rule)
            Set-Acl $ClonePath $acl
            Write-Log -message "Successfully set permissions on $ClonePath" -severity 'INFO'
        }
        catch {
            Write-Log -message "Failed to set permissions on $ClonePath`: $($_.Exception.Message)" -severity 'ERROR'
            exit 2
        }
    }

    Write-Log -message "Starting mozilla-unified clone to $ClonePath" -severity 'INFO'

    try {
        Write-Log -message "Cloning $Repository to $ClonePath" -severity 'INFO'

        $TempClonePath = Join-Path $env:TEMP "hg-shared_$(Get-Date -Format 'yyyyMMdd_HHmmss')"

        ## Initialize the $clonePath
        $initSplat = @{
            FilePath = $Hg
            ArgumentList = @(
                "init",
                $ClonePath
            )
            Wait = $true
            PassThru = $true
            NoNewWindow = $true
        }

        $initProcess = Start-Process @initSplat

        if ($initProcess.ExitCode -eq 0) {
            Write-Log -message "Successfully initialized $ClonePath" -severity 'INFO'
            exit 0
        }
        else {
            Write-Log -message "Failed to initialize $ClonePath. Exit code: $($initProcess.ExitCode)" -severity 'ERROR'
            exit 1
        }

        $Splat = @{
            FilePath     = $Hg
            ArgumentList = @(
                "robustcheckout",
                "--sharebase",
                $TempClonePath,
                "--config",
                "extensions.robustcheckout=C:\\mozilla-build\\robustcheckout.py",
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

        if ($hgProcess.ExitCode -eq 0) {
            Write-Log -message "Successfully cloned mozilla-unified to $ClonePath" -severity 'INFO'
            exit 0
        }
        else {
            Write-Log -message "Failed to clone mozilla-unified. Exit code: $($hgProcess.ExitCode)" -severity 'ERROR'
            exit 1
        }
    }
    catch {
        Write-Log -message "Error cloning mozilla-unified: $($_.Exception.Message)" -severity 'ERROR'
        exit 6
    }
}