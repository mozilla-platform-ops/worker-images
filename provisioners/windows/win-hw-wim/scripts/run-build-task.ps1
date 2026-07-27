<#
.SYNOPSIS
  On-VM build wrapper run as a scheduled task. Runs New-WinHwWim.ps1 to completion,
  tees output to a log, and writes a completion marker with the exit code so the
  workflow (on the GH runner) can poll for done/success without the ~90-min
  run-command limit applying to the build itself.

.DESCRIPTION
  Writes:
    C:\win-hw-wim-build\build.log   full build output (append-tee)
    C:\win-hw-wim-build\build.done  the exit code (0 = success) — created only when done
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Image,
    [string] $BuildId,
    [string] $IdentityClientId
)
$base = 'C:\win-hw-wim-build'
New-Item -ItemType Directory -Path $base -Force | Out-Null
$log  = Join-Path $base 'build.log'
$done = Join-Path $base 'build.done'
Remove-Item $log, $done -ErrorAction SilentlyContinue

# Refresh PATH from the machine env so packer/az/azcopy/git resolve under the
# scheduled task (choco updated the machine PATH after the guest agent started).
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

$nuc  = 'C:\worker-images\provisioners\windows\win-hw-wim\bin\WinHwWim\New-WinHwWim.ps1'
$rc = 0
try {
    $a = @('-Image', $Image)
    if ($BuildId) { $a += @('-BuildId', $BuildId) }
    if ($IdentityClientId) { $a += @('-IdentityClientId', $IdentityClientId) }
    # Run in a child process so we get a reliable exit code (New-WinHwWim uses -EA Stop).
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $nuc @a *>&1 | Tee-Object -FilePath $log
    $rc = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
}
catch {
    $rc = 1
    $_ | Out-String | Add-Content -Path $log
}
Set-Content -Path $done -Value $rc
