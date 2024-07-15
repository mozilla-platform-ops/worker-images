function Get-MozillaBuildPythonPackages {
    [System.IO.FileInfo]
    [ValidateScript({
            if ( -Not ($_ | Test-Path) ) {
                throw "File or folder does not exist"
            }
            return $true
        })]
    $RequirementsFile
    
    Get-Content $RequirementsFile | ForEach-Object {
        $p = $psitem -split "=="
        [PSCustomObject]@{
            Name    = $p[0]
            Version = $p[1]
        }
    } | Sort-Object -Property Name 
}