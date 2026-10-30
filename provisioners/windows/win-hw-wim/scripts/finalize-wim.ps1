[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $VmName,
    [Parameter(Mandatory)] [string] $Username,
    [ValidateRange(1, 1800)] [int] $ShutdownTimeoutSec = 180
)
$ErrorActionPreference = 'Stop'
if (-not $env:PKR_VAR_winrm_password) { throw 'PKR_VAR_winrm_password is required for PowerShell Direct.' }
$credential = [PSCredential]::new($Username, (ConvertTo-SecureString $env:PKR_VAR_winrm_password -AsPlainText -Force))
$session = $null
try {
    if ((Get-VM -Name $VmName).State -ne 'Running') { throw 'Build VM is not running.' }
    $session = New-PSSession -VMName $VmName -Credential $credential
    Write-Output 'WIM-WATCHDOG-STOP: finalizing over PowerShell Direct.'
    $result = Invoke-Command -Session $session -FilePath (Join-Path $PSScriptRoot 'sysprep-generalize.ps1') -ArgumentList $true
    $result | Write-Output
    if ($result -notcontains 'WIM_FINALIZE_OK') { throw 'Guest finalization did not confirm success.' }
    $deadline = (Get-Date).AddSeconds($ShutdownTimeoutSec)
    while ((Get-VM -Name $VmName).State -ne 'Off') {
        if ((Get-Date) -ge $deadline) { throw 'Timed out waiting for graceful shutdown; refusing capture.' }
        Start-Sleep -Seconds 2
    }
    Write-Output 'WIM guest finalized and powered off.'
}
finally {
    if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
}
