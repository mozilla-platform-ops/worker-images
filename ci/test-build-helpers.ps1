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
    if ($args[0] -eq 'build' -and $args[-1] -eq 'azure.pkr.hcl') {
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
    foreach ($command in @('init', 'build')) {
        $global:failCommand = $command
        foreach ($cloud in @('aws', 'azure')) {
            $global:packerCalls = @()
            $failed = $false
            try {
                if ($cloud -eq 'aws') {
                    New-AWSWorkerImage -Key generic-worker-ubuntu-24-04 -Region us-west-2
                } else {
                    New-AzWorkerImage -Team tceng -Key generic-worker-win2022 -Location $env:PKR_VAR_build_location `
                        -Client_ID test -Subscription_ID test -Tenant_ID test -Application_ID test `
                        -oidc_request_url https://example.invalid -oidc_request_token test
                }
            } catch { $failed = $true }
            Assert $failed "$cloud tceng $command failure was hidden"
            Assert ($global:packerCalls.Count -eq $(if ($command -eq 'init') { 1 } else { 2 })) "$cloud did not stop at the failing Packer command"
        }
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
# Exercise the composite's actual scripts without cloud credentials or Packer.
$action = ConvertFrom-Yaml (Get-Content .github/actions/packer-build/action.yml -Raw)
$validate = [scriptblock]::Create(($action.runs.steps | Where-Object { $_['id'] -eq 'config' }).run)
$build = [scriptblock]::Create(($action.runs.steps | Where-Object { $_['id'] -eq 'build' }).run)
$env:GITHUB_OUTPUT = [IO.Path]::GetTempFileName()
$env:GITHUB_ENV = [IO.Path]::GetTempFileName()
foreach ($name in @('GITHUB_TOKEN', 'CLIENT_ID', 'SUBSCRIPTION_ID', 'TENANT_ID', 'APPLICATION_ID', 'ACTIONS_ID_TOKEN_REQUEST_URL', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN')) {
    [Environment]::SetEnvironmentVariable($name, 'test')
}
function global:Import-Module { param($Name) }
function global:New-AzSharedWorkerImage {
    param($Key, $github_token, $Client_ID, $Subscription_ID, $Tenant_ID, $Application_ID, $oidc_request_url, $oidc_request_token, [switch]$DeferReplication)
    $global:actionCall = $PSBoundParameters
    $global:actionCall['builder'] = 'azure'
    $env:PKR_VAR_sharedimage_version = '1.2.3'
}
function global:New-AzWorkerImage {
    param($Team, $Key, $Location, $Client_ID, $Subscription_ID, $Tenant_ID, $Application_ID, $oidc_request_url, $oidc_request_token)
    $global:actionCall = $PSBoundParameters
    $global:actionCall['builder'] = 'azure-tceng'
}
function global:New-GCPWorkerImage {
    param($Key, $Github_token, $Team)
    $global:actionCall = $PSBoundParameters
    $global:actionCall['builder'] = if ($Team -eq 'tceng') { 'gcp-tceng' } else { 'gcp' }
}
function global:New-AWSWorkerImage {
    param($Key, $Region)
    if ($env:CONFIG -eq 'fail-build') { throw 'Simulated build failure' }
    $global:actionCall = $PSBoundParameters
    $global:actionCall['builder'] = 'aws-tceng'
}
try {
    foreach ($mode in @('azure', 'gcp', 'azure-tceng', 'gcp-tceng', 'aws-tceng')) {
        $env:IMAGE_BUILDER = $mode
        $env:CONFIG = switch ($mode) {
            'azure' { 'trusted-win2025-64-24h2' }
            'gcp' { 'gw-fxci-gcp-l1-2404-headless-alpha' }
            default { 'generic-worker-ubuntu-24-04' }
        }
        $env:BUILD_LOCATION = 'us-west-2'
        $env:TASKCLUSTER_REF = 'test-ref'
        $env:DEFER_REPLICATION = ($mode -eq 'azure').ToString().ToLowerInvariant()
        Clear-Content $env:GITHUB_OUTPUT
        & $validate
        $template = (Get-Content $env:GITHUB_OUTPUT) -replace '^template=', ''
        Assert (Test-Path $template) 'cache must hash an existing template'
        $global:actionCall = $null
        & $build
        Assert ($global:actionCall.builder -eq $mode) "Wrong helper for $mode"
        Assert ($global:actionCall.Key -eq $env:CONFIG) "Wrong config for $mode"
        Assert ($env:PKR_VAR_taskcluster_ref -eq 'test-ref') 'Taskcluster ref lost'
        if ($mode -in 'azure-tceng', 'gcp-tceng') { Assert ($global:actionCall.Team -eq 'tceng') 'tceng routing lost' }
        if ($mode -eq 'aws-tceng') { Assert ($global:actionCall.Region -eq 'us-west-2') 'AWS region lost' }
        if ($mode -eq 'azure-tceng') { Assert ($global:actionCall.Location -eq 'us-west-2') 'Azure location lost' }
        if ($mode -eq 'azure') {
            Assert $global:actionCall.DeferReplication 'deferred replication lost'
            Assert ((Get-Content $env:GITHUB_ENV) -contains 'sharedimageversion=1.2.3') 'artifact version lost'
        }
    }
    $env:CONFIG = 'fail-build'
    $failed = $false
    try { & $build } catch { $failed = $true }
    Assert $failed 'composite swallowed a build failure'
    foreach ($case in @('builder', 'config', 'location', 'defer')) {
        $env:IMAGE_BUILDER = 'aws-tceng'; $env:CONFIG = 'generic-worker-ubuntu-24-04'
        $env:BUILD_LOCATION = 'us-west-2'; $env:DEFER_REPLICATION = 'false'
        switch ($case) {
            'builder' { $env:IMAGE_BUILDER = 'invalid' }
            'config' { $env:CONFIG = '../README' }
            'location' { $env:BUILD_LOCATION = '' }
            'defer' { $env:DEFER_REPLICATION = 'true' }
        }
        $rejected = $false
        try { & $validate } catch { $rejected = $true }
        Assert $rejected "Invalid composite $case accepted"
    }
} finally {
    Remove-Item $env:GITHUB_OUTPUT, $env:GITHUB_ENV
    foreach ($name in @('Import-Module', 'New-AzSharedWorkerImage', 'New-AzWorkerImage', 'New-GCPWorkerImage', 'New-AWSWorkerImage')) {
        Remove-Item "Function:/$name"
    }
}
Write-Host 'Build helper checks passed.'
