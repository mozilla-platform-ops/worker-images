function Get-GenericWorkerVersion {
    [CmdletBinding()]
    param (
        [String]
        $FilePath = "C:\generic-worker\generic-worker.exe",
        
        [String]
        $StandardOutput = "C:\gwversion.txt"
    )
    
    ## Generic Worker
    Start-Process -FilePath $FilePath -ArgumentList "--short-version" -RedirectStandardOutput $StandardOutput -Wait -NoNewWindow
    [PSCustomObject]@{
        Name = "GenericWorker"
        Version = (Get-Content $StandardOutput)[-1]
    }
    $null = Remove-Item -Path $StandardOutput -Force -ErrorAction SilentlyContinue
}