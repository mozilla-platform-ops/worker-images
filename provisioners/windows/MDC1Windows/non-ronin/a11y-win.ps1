# Staged as D:\scripts\Get-Bootstrap.ps1 by OS-deploy for the a11y-win pool.
# No Puppet, Ronin checkout, or Taskcluster registration.
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath 'D:\scripts\non-ronin.json' -Raw | ConvertFrom-Json
if ($config.pool -ne 'a11y-win') { throw 'Incorrect pool configuration for a11y-win.' }
if ($config.kms_key -notmatch '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$' -or
    $config.kms_server -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*(?::[0-9]{1,5})?$') {
    throw 'Invalid KMS key or server in the deployment configuration.'
}

$slmgr = Join-Path $env:SystemRoot 'System32\slmgr.vbs'
foreach ($arguments in @(@('/ipk', $config.kms_key), @('/skms', $config.kms_server), @('/ato'))) {
    & cscript.exe //Nologo $slmgr @arguments
    if ($LASTEXITCODE -ne 0) { throw "KMS setup failed: $($arguments[0]) (exit $LASTEXITCODE)." }
}
$partialKey = $config.kms_key.Substring($config.kms_key.Length - 5)
$license = Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey='$partialKey'"
if (-not ($license | Where-Object { $_.LicenseStatus -eq 1 })) { throw 'Windows KMS activation did not reach the licensed state.' }

# Remove provisioning credentials and answer files only after successful setup.
foreach ($path in @('D:\secrets', 'C:\bootstrap\vault.yaml', 'D:\scripts\non-ronin.json',
    'C:\Windows\Panther\unattend.xml', 'C:\Windows\Panther\Unattend\unattend.xml')) {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
}
Get-ChildItem -LiteralPath 'D:\' -Filter autounattend.xml -Recurse -File |
    Remove-Item -Force
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -LiteralPath $winlogon -Name AutoAdminLogon -Value '0'
Remove-ItemProperty -LiteralPath $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue
Write-Host "a11y-win provisioning complete ($($config.worker_images_revision))."
