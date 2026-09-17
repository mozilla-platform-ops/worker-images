function Get-GenericWorkerVersion {
    [CmdletBinding()]
    param (
        [String]
        $FilePath = "C:\generic-worker\generic-worker.exe",

        [String]
        $StandardOutput = "C:\gwversion.txt"
    )

    # Not every image ships the Taskcluster binaries: the win-hw-wim bake role excludes
    # windows_worker_runner (generic-worker + worker-runner are installed at DEPLOY time),
    # and Start-Process on a missing path throws a TERMINATING error, which Set-ReleaseNotes'
    # trap rethrows - killing the build right before Sysprep. Report nothing instead, so the
    # release notes just omit the row. No change where the binary exists.
    if (-not (Test-Path $FilePath)) {
        Write-Verbose ('{0}: {1} not present; omitting from the release notes' -f $MyInvocation.MyCommand.Name, $FilePath)
        return
    }

    ## Generic Worker
    Start-Process -FilePath $FilePath -ArgumentList "--short-version" -RedirectStandardOutput $StandardOutput -Wait -NoNewWindow
    [PSCustomObject]@{
        Name = "GenericWorker"
        Version = (Get-Content $StandardOutput)
    }
    $null = Remove-Item -Path $StandardOutput -Force -ErrorAction SilentlyContinue
}