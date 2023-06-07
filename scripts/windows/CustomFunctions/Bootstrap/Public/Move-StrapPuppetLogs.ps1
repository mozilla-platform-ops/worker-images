function Move-StrapPuppetLogs {
    param (
        [string] $logdir = "$env:systemdrive\logs",
        [string] $bootstraplogdir = "$logdir\bootstrap"
    )
    New-Item -ItemType Directory -Force -Path $bootstraplogdir
    Get-ChildItem -Path $logdir\*.log -Recurse | Move-Item -Destination $bootstraplogdir -ErrorAction SilentlyContinue
}