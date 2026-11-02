[CmdletBinding()]
param([Parameter(Mandatory)] [string] $Wim)
$ErrorActionPreference = 'Stop'
$Wim = (Resolve-Path -LiteralPath $Wim).ProviderPath
(Get-Item -LiteralPath $Wim).IsReadOnly = $false
if (Test-Path -LiteralPath "$Wim.sha256") { Remove-Item -LiteralPath "$Wim.sha256" }
. (Join-Path $PSScriptRoot 'post-install.ps1')
$mount = Join-Path ([IO.Path]::GetTempPath()) ('post-install-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $mount | Out-Null
$mounted = $false
try {
    foreach ($image in (Get-WindowsImage -ImagePath $Wim)) {
        Mount-WindowsImage -ImagePath $Wim -Index $image.ImageIndex -Path $mount -CheckIntegrity | Out-Null
        $mounted = $true
        Install-PostInstallCleanup -WindowsRoot (Join-Path $mount 'Windows')
        Dismount-WindowsImage -Path $mount -Save -CheckIntegrity | Out-Null
        $mounted = $false
    }
}
finally {
    if ($mounted) { Dismount-WindowsImage -Path $mount -Discard | Out-Null }
    Remove-Item -LiteralPath $mount -Recurse -Force
}
$hash = (Get-FileHash -LiteralPath $Wim -Algorithm SHA256).Hash.ToLower()
[IO.File]::WriteAllText("$Wim.sha256", "$hash  $(Split-Path -Leaf $Wim)", [Text.Encoding]::ASCII)
