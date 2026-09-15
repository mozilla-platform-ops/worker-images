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
$global:packerCalls = @()
$global:failCommand = ''
$global:skuOverride = $null
$global:skuExit = 0
function global:az {
    $global:LASTEXITCODE = $global:skuExit
    if ($null -ne $global:skuOverride) { return $global:skuOverride }
    ConvertTo-Json -Depth 10 -InputObject @(@{
        resourceType = 'virtualMachines'; name = $env:PKR_VAR_vm_size
        locations = @($env:PKR_VAR_build_location); restrictions = @()
        capabilities = @(@{ name = 'LowPriorityCapable'; value = 'True' })
    })
}
function global:packer {
    $global:packerCalls += ,$args
    $global:LASTEXITCODE = if ($args[0] -eq $global:failCommand) { 7 } else { 0 }
    if ($args[0] -eq 'build') {
        foreach ($archive in @($env:PKR_VAR_bootstrap_archive, $env:PKR_VAR_tests_archive)) {
            $zip = [IO.Compression.ZipFile]::OpenRead($archive)
            try {
                Assert ($zip.Entries.Count -gt 0) 'archive is empty'
                if ($archive.EndsWith('Bootstrap.zip')) {
                    Assert ($zip.Entries.FullName -contains 'Bootstrap/Bootstrap.psm1') 'Bootstrap module root missing'
                } else {
                    Assert ($zip.Entries.FullName -contains 'git.tests.ps1') 'tests must be at archive root'
                }
            } finally { $zip.Dispose() }
        }
    }
}
if (Test-Path win11-64-24h2-replication.json) { throw 'Move the existing replication manifest before running these checks.' }
try {
    foreach ($config in Get-ChildItem config/*win*.yaml | Where-Object Name -ne 'windows_production_defaults.yaml') {
        New-AzSharedWorkerImage -Key $config.BaseName -Subscription_ID test-subscription
        Assert ($env:PKR_VAR_use_keyvault -eq ($config.BaseName.StartsWith('trusted-')).ToString().ToLowerInvariant()) 'trust selection failed'
        Assert (-not (Test-Path $env:PKR_VAR_bootstrap_archive)) 'staging directory leaked'
    }
    New-AzSharedWorkerImage -Key win11-64-24h2 -Subscription_ID test-subscription -DeferReplication
    $manifest = Get-Content win11-64-24h2-replication.json -Raw | ConvertFrom-Json
    Assert ($manifest.regions.Count -eq 11 -and $manifest.regions -contains 'centralindia' -and $manifest.regions -contains 'westus3') 'pool-specific production targets incomplete'
    Assert ($env:PKR_VAR_replication_regions -eq '["centralus"]') 'deferred build must publish locally'
    foreach ($command in @('init', 'build')) {
        $global:failCommand = $command
        $global:packerCalls = @()
        $failed = $false
        try { New-AzSharedWorkerImage -Key win11-64-24h2 -Subscription_ID test-subscription } catch { $failed = $true }
        Assert $failed "Packer $command failure was hidden"
        if ($command -eq 'init') { Assert ($global:packerCalls.Count -eq 1) 'build ran after init failure' }
    }
    $env:CONFIG = '../README'
    $rejected = $false
    try { & ./ci/validate-image-config.ps1 } catch { $rejected = $true }
    Assert $rejected 'path traversal accepted'
} finally {
    Remove-Item Function:/packer
    Remove-Item win11-64-24h2-replication.json -ErrorAction SilentlyContinue
}
$output = [IO.Path]::GetTempFileName()
$env:GITHUB_OUTPUT = $output
$env:ORIGINAL_OS_INT_MATRIX = '{"config":["alpha","failed"]}'
$global:jobPages = '[{"jobs":[{"name":"Build alpha","conclusion":"success"}]},{"jobs":[{"name":"Build trusted-alpha","conclusion":"success"},{"name":"Build failed","conclusion":"failure"}]}]'
function global:gh { $global:LASTEXITCODE = 0; $global:jobPages }
try {
    & ./ci/find-successful-builds.ps1
    $values = Get-Content $output
    Assert ($values -contains 'os_integration_matrix={"config":["alpha"]}') 'matrix must contain only successful requested configs'
    Assert ($values -contains 'wiz_matrix={"config":["alpha"]}') 'Wiz must exclude trusted configs'
    Clear-Content $output
    $global:jobPages = '[{"jobs":[]}]'
    & ./ci/find-successful-builds.ps1
    Assert ((Get-Content $output) -contains 'os_integration_count=0') 'empty matrix must signal downstream skip'
} finally {
    Remove-Item Function:/gh
    Remove-Item $output
}
. ./bin/WorkerImages/Private/Assert-AzVmSkuAvailable.ps1
$sku = @{
    name = 'Standard_Test'; resourceType = 'virtualMachines'; locations = @('eastus')
    restrictions = @(); capabilities = @(@{ name = 'LowPriorityCapable'; value = 'True' })
}
try {
    foreach ($case in @('supported', 'zone-only', 'other-region', 'restricted', 'partial-name', 'missing', 'api-error', 'no-spot')) {
        $entry = $sku.Clone()
        $global:skuExit = 0
        switch ($case) {
            'zone-only' { $entry.restrictions = @(@{ type = 'Zone'; values = @('eastus') }) }
            'other-region' { $entry.restrictions = @(@{ type = 'Location'; values = @('westus') }) }
            'restricted' { $entry.restrictions = @(@{ type = 'Location'; restrictionInfo = @{ locations = @('eastus') } }) }
            'partial-name' { $entry.name = 'Standard_Test_Extra' }
            'api-error' { $global:skuExit = 1 }
            'no-spot' { $entry.capabilities = @() }
        }
        $global:skuOverride = ConvertTo-Json -InputObject @($entry) -Depth 10
        if ($case -eq 'missing') { $global:skuOverride = '[]' }
        $passed = $true
        try { Assert-AzVmSkuAvailable -SubscriptionId test -Location 'East US' -VmSize Standard_Test -UseSpot $true } catch { $passed = $false }
        Assert ($passed -eq ($case -in 'supported', 'zone-only', 'other-region')) "Unexpected SKU preflight result: $case"
    }
} finally { Remove-Item Function:/az }
Write-Host 'Build helper checks passed.'
