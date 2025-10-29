function Get-LiveLogVersion {
    [CmdletBinding()]
    param (
        [String]
        $FilePath = "C:\generic-worker\livelog.exe",

        [String]
        $StandardOutput = "C:\livelogversion.txt"
    )

    Start-Process -FilePath $FilePath -ArgumentList "--short-version" -RedirectStandardOutput $StandardOutput -Wait -NoNewWindow
    [PSCustomObject]@{
        Name = "LiveLog"
        Version = (Get-Content $StandardOutput)
    }

    $null = Remove-Item -Path $StandardOutput -Force -ErrorAction SilentlyContinue

}