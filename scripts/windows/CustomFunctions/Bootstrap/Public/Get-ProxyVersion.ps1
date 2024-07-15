function Get-ProxyVersion {
    [CmdletBinding()]
    param (
        [String]
        $FilePath = "C:\generic-worker\taskcluster-proxy.exe",
        
        [String]
        $StandardOutput = "C:\proxyversion.txt"
    )
    
    Start-Process -FilePath $FilePath -ArgumentList "--short-version" -RedirectStandardOutput $StandardOutput -Wait -NoNewWindow
    [PSCustomObject]@{
        Name = "Proxy"
        Version = (Get-Content $StandardOutput)
    }

    $null = Remove-Item -Path $StandardOutput -Force -ErrorAction SilentlyContinue

}