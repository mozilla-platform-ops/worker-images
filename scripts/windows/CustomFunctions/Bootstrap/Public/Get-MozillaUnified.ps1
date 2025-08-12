function Get-MozillaUnified {
    [CmdletBinding()]
    param (
        [String]
        $ClonePath = "C:\mozilla-unified",
        
        [String]
        $Repository = "https://hg.mozilla.org/mozilla-unified",

        [String]
        $Hg = "C:\Program Files\Mercurial\hg.exe"
    )
    
    Write-Log -message "Starting mozilla-unified clone to $ClonePath" -severity 'INFO'
    
    try {
        Write-Log -message "Cloning $Repository to $ClonePath" -severity 'INFO'
        $Splat = @{
            FilePath = $Hg
            ArgumentList = @("clone", $Repository, $ClonePath)
            Wait = $true
            PassThru = $true
            NoNewWindow = $true
        }
        $hgProcess = Start-Process @Splat
        
        if ($hgProcess.ExitCode -eq 0) {
            Write-Log -message "Successfully cloned mozilla-unified to $ClonePath" -severity 'INFO'
            return $true
        }
        else {
            Write-Log -message "Failed to clone mozilla-unified. Exit code: $($hgProcess.ExitCode)" -severity 'ERROR'
            return $false
        }
    }
    catch {
        Write-Log -message "Error cloning mozilla-unified: $($_.Exception.Message)" -severity 'ERROR'
        return $false
    }
}