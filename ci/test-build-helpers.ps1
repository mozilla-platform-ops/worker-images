$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Set-Location "$PSScriptRoot/.."
. ./bin/WorkerImages/Private/Merge-ImageDefaults.ps1

function Assert($Condition, $Message) {
    if (-not $Condition) { throw $Message }
}
$defaults = @{ vm = @{ spot = $true; tags = @{ inherited = 'pin'; override = 'old' }; list = @(1) } }
$image = @{ vm = @{ spot = $false; tags = @{ override = 'new' }; list = @(); empty = $null } }
$merged = Merge-ImageDefaults $defaults $image
Assert ($merged.vm.spot -eq $false) 'false must override defaults'
Assert ($merged.vm.list.Count -eq 0) 'empty arrays must override defaults'
Assert ($merged.vm.ContainsKey('empty')) 'explicit null must be retained'
Assert ($merged.vm.tags.inherited -eq 'pin' -and $merged.vm.tags.override -eq 'new') 'nested merge failed'
Assert ($defaults.vm.tags.override -eq 'old') 'merge mutated defaults'

foreach ($module in @('bin/WorkerImages/WorkerImages', 'scripts/windows/CustomFunctions/Bootstrap/Bootstrap')) {
    $manifest = Import-PowerShellDataFile "$module.psd1"
    $public = @(Get-ChildItem "$(Split-Path $module)/Public/*.ps1" | ForEach-Object BaseName)
    Assert (-not (Compare-Object $public $manifest.FunctionsToExport)) "Manifest exports drifted from public functions: $module"
}
Import-Module ./scripts/windows/CustomFunctions/Bootstrap/Bootstrap.psd1 -Force
Assert ($null -ne (Get-Command Get-LiveLogVersion)) 'release notes need the LiveLog version helper'
Assert ($null -ne (Get-Command Show-vcc2019)) 'active tester tests need the VCC2019 helper'
if ($IsWindows) {
    $name = "worker-images-test-$([guid]::NewGuid())"
    $key = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$name"
    try {
        New-Item $key -Force | Out-Null
        # Empty machineName selects the local registry without a remote service.
        Assert (-not (Get-InstalledSoftware -ComputerName '' | Where-Object Name -eq $name)) 'blank names should be hidden'
        Assert (@(Get-InstalledSoftware -ComputerName '' -IncludeBlankNames | Where-Object Name -eq $name).Count -eq 1) 'IncludeBlankNames ignored'
        Set-ItemProperty $key DisplayName 'Worker-images test'
        $inventory = @('', '' | Get-InstalledSoftware | Where-Object Name -eq $name)
        Assert ($inventory.Count -eq 2) 'pipeline computers were not processed individually'
    } finally { Remove-Item $key -Recurse -Force }
}
Import-Module ./bin/WorkerImages/WorkerImages.psd1 -Force
Write-Host 'PowerShell helper checks passed.'
