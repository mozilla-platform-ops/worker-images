Invoke-WebRequest "https://github.com/mozilla-platform-ops/worker-images/archive/refs/heads/main.zip" -OutFile C:\main.zip -UseBasicParsing
Expand-Archive C:\main.zip
Copy-Item "C:\main\worker-images-main\scripts\windows\CustomFunctions\Bootstrap" "C:\Windows\System32\WindowsPowerShell\v1.0\Modules" -Recurse -Force -Verbose
Import-Module "C:\Windows\System32\WindowsPowerShell\v1.0\Modules\Bootstrap\Bootstrap.psd1"
Disable-AntiVirus
Set-Logging
Install-AzPreReq
Set-RoninRegOptions -Worker_Pool_ID "win11-64-2009" -Base_Image "win11642009azure" -src_Organisation "jwmoss" -src_repository "ronin_puppet" -src_branch "cloud_windows"
Set-AzRoninRepo -role "win11642009azure" -sourceOrg "jwmoss" -sourceRepo "ronin_puppet" -sourceBranch "cloud_windows" -deploymentId "f666bd3"