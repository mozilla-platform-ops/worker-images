function Get-MozillaBuildPythonPackages {
    [CmdletBinding()]
    param (
        [String]
        $RequirementsFile = "C:\requirements.txt"
    )
   
    if (-Not (Test-Path $RequirementsFile)) {
        C:\mozilla-build\python3\python.exe -m pip freeze --all > $RequirementsFile
    }

    Get-Content $RequirementsFile | ForEach-Object {
        $p = $psitem -split "=="
        [PSCustomObject]@{
            Name    = $p[0]
            Version = $p[1]
        }
    } | Sort-Object -Property Name 
}