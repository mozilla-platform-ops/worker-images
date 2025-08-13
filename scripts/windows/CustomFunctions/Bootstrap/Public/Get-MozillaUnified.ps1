function Get-MozillaUnified {
    [CmdletBinding()]
    param (
        [String]
        $ClonePath = "C:\hg-shared",

        [String]
        $TempClonePath = "C:\hg-shared_temp",
        
        [String]
        $Repository = "https://hg.mozilla.org/mozilla-unified",

        [String]
        $Hg = "C:\Program Files\Mercurial\hg.exe"
    )
    
    Write-Log -message "Starting mozilla-unified clone to $ClonePath" -severity 'INFO'
    
    try {
        Write-Log -message "Cloning $Repository to $ClonePath" -severity 'INFO'

        $null = New-Item -Path $TempClonePath -ItemType Directory -Force
        if (-Not (Test-Path $TempClonePath)) {
            Write-Log -message "Failed to create temporary clone path: $TempClonePath" -severity 'ERROR'
            exit 1
        }

        $Splat = @{
            FilePath = $Hg
            ArgumentList = @(
                "robustcheckout",
                "--sharebase",
                $ClonePath,
                "--config",
                "extensions.robustcheckout=C:\\mozilla-build\\robustcheckout.py",
                "--revision",
                "tip",
                $Repository,
                $TempClonePath
            )
            Wait = $true
            PassThru = $true
            NoNewWindow = $true
        }
        $hgProcess = Start-Process @Splat
        
        ## Now remove the tempClonePath
        Remove-Item -Path $TempClonePath -Recurse -Force

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