DISM /cleanup-wim

## mount the wim into
if (-Not(Test-Path "C:\MOUNT" )) {
    New-Item -Path C:\ -Name MOUNT -ItemType Directory -Force
}

## run dism to mount into that mount directory
DISM /Mount-Image /ImageFile:"C:\CustomWinPE\winpe.wim" /index:1 /MountDir:'C:\MOUNT'

## make the updates to the script
Write-host "Update the script in C:\MOUNT\scripts\deployment.ps1"

## rename the winpe yo'ure about to update
## winpe - Ver22.wim

## Update the changelog in C:\CustomWinPE\changelog.txt

## once changes are made, commit them to the wim
DISM /UnMount-Image /MountDir:'C:\MOUNT' /commit

## Update WDS
## Properties --> Boot Images --> Replace Microsoft WinPE and add Winpe - Ver22.wim
