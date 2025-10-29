function Get-WorkerRunnerVersion {
    [CmdletBinding()]
    param (
        [String]
        $FilePath = "C:\worker-runner\start-worker.exe",

        [String]
        $StandardOutput = "C:\gwversion.txt"
    )

    Start-Process -FilePath $FilePath -ArgumentList "--short-version" -RedirectStandardOutput $StandardOutput -Wait -NoNewWindow
    [Hashtable]@{
        Name = "StartWorker"
        Version = (Get-Content $StandardOutput)
    }

    $null = Remove-Item -Path $StandardOutput -Force -ErrorAction SilentlyContinue

}