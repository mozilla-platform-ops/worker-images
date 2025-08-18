function Get-MozillaUnified {
    [CmdletBinding()]
    param (
        [String]
        $ClonePath = "C:\vcs-checkout",
        
        [String]
        $Repository = "https://hg.mozilla.org/mozilla-unified",

        [String]
        $Hg = "C:\Program Files\Mercurial\hg.exe"
    )
    ## Let's capture both a string and boolean
    if ($ENV:clone_mozilla_unified -match "false|false" -or $ENV:clone_mozilla_unified -eq $false) {
        Write-Log -message "Skipping clone due to $ENV:clone_mozilla_unified" -severity 'INFO'
        exit 0
    }

    Write-Log -message "Starting mozilla-unified clone to $ClonePath" -severity 'INFO'
    
    ## Test for the existence of clone_mozilla_unified to true or false
    if ($ENV:clone_mozilla_unified -match "false|false" -or $ENV:clone_mozilla_unified -eq $false) {
        Write-Log -message "Skipping clone due to $ENV:clone_mozilla_unified" -severity 'INFO'
        exit 0
    }

    try {
        Write-Log -message "Cloning $Repository to $ClonePath" -severity 'INFO'
    
        $Splat = @{
            FilePath     = $Hg
            ArgumentList = @(
                "clone",
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