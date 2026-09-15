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
$output = [IO.Path]::GetTempFileName()
$env:GITHUB_OUTPUT = $output
$env:ORIGINAL_OS_INT_MATRIX = '{"config":["alpha","nested","failed"]}'
$global:jobPages = '[{"jobs":[{"name":"Build alpha","conclusion":"success"}]},{"jobs":[{"name":"Build nested / Packer","conclusion":"success"},{"name":"Build bogus / Authorize","conclusion":"success"},{"name":"Build trusted-alpha / Packer","conclusion":"success"},{"name":"Build failed / Packer","conclusion":"failure"}]}]'
function global:gh { $global:LASTEXITCODE = 0; $global:jobPages }
try {
    & ./ci/find-successful-builds.ps1
    $values = Get-Content $output
    Assert ($values -contains 'os_integration_matrix={"config":["alpha","nested"]}') 'matrix must contain only successful requested configs'
    Assert ($values -contains 'wiz_matrix={"config":["alpha","nested"]}') 'Wiz must exclude trusted configs'
    Clear-Content $output
    $global:jobPages = '[{"jobs":[]}]'
    & ./ci/find-successful-builds.ps1
    Assert ((Get-Content $output) -contains 'os_integration_count=0') 'empty matrix must signal downstream skip'
} finally {
    Remove-Item Function:/gh
    Remove-Item $output
}
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
if (Test-Path win11-64-24h2-replication.json) { throw 'Move the existing replication request before running these checks.' }
$temp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temp
$env:GITHUB_ENV = "$temp/environment"
$env:RUNNER_TEMP = $temp
$global:skuOverride = $null
$global:skuExit = 0
function global:az {
    $global:LASTEXITCODE = $global:skuExit
    if ($null -ne $global:skuOverride) { return $global:skuOverride }
    $location = $args[[array]::IndexOf($args, '--location') + 1]
    ConvertTo-Json -Depth 10 -InputObject @(@{
        resourceType = 'virtualMachines'; name = $env:PKR_VAR_vm_size
        locations = @($location); restrictions = @()
        capabilities = @(@{ name = 'LowPriorityCapable'; value = 'True' })
    })
}
function global:packer { throw 'Preparing variables must not invoke Packer.' }
try {
    foreach ($region in @('--subscription=other', "eastus`nOTHER=value")) {
        $failed = $false
        try { Set-AWSWorkerImageVariables -Key generic-worker-ubuntu-24-04 -Region $region } catch { $failed = $true }
        Assert $failed 'invalid AWS region accepted'
        $failed = $false
        try {
            Set-AzWorkerImageVariables -Team tceng -Key generic-worker-win2022 -Location $region `
                -Client_ID test -Subscription_ID test -Tenant_ID test -Application_ID test `
                -oidc_request_url https://example.invalid -oidc_request_token test
        } catch { $failed = $true }
        Assert $failed 'invalid Azure location accepted'
    }
    $env:CONFIG = '../README'
    $failed = $false
    try { & ./ci/validate-image-config.ps1 -Family all } catch { $failed = $true }
    Assert $failed 'config path traversal accepted'
    Set-GCPWorkerImageVariables -Key gw-fxci-gcp-l1-2404-headless-alpha
    Assert ($env:PKR_VAR_config -eq 'gw-fxci-gcp-l1-2404-headless-alpha') 'GCP config lost'
    Assert ($env:PKR_VAR_use_keyvault -eq 'false') 'GCP trust selection lost'
    Set-GCPWorkerImageVariables -Key generic-worker-ubuntu-24-04 -Team tceng
    Assert ($env:PKR_VAR_image_name.EndsWith($env:PKR_VAR_uuid)) 'tceng GCP UUID lost'
    Set-AWSWorkerImageVariables -Key generic-worker-ubuntu-24-04 -Region us-west-2
    Assert ($env:PKR_VAR_region -eq 'us-west-2') 'AWS region lost'
    Assert ($env:PKR_VAR_ami_name.EndsWith($env:PKR_VAR_uuid)) 'AWS UUID lost'
    Set-AzWorkerImageVariables -Team tceng -Key generic-worker-win2022 -Location eastus `
        -Client_ID test -Subscription_ID test -Tenant_ID test -Application_ID test `
        -oidc_request_url https://example.invalid -oidc_request_token test
    Assert ($env:PKR_VAR_location -eq 'eastus') 'Azure location lost'
    Set-AzSharedWorkerImageVariables -Key win11-64-24h2 -Subscription_ID test
    Assert ($env:PKR_VAR_config -eq 'win11-64-24h2') 'FXCI Azure config lost'

    # Environment handoff uses delimited values, never executable PowerShell.
    . ./bin/WorkerImages/Private/Export-WorkerImageEnvironment.ps1
    $env:PKR_VAR_fixture = "first`nSECOND_VARIABLE=not-an-assignment"
    $env:PACKER_GITHUB_API_TOKEN = 'test-token'
    Clear-Content $env:GITHUB_ENV
    Export-WorkerImageEnvironment
    $records = [regex]::Matches((Get-Content $env:GITHUB_ENV -Raw), '(?m)^([^\r\n]+)<<([a-f0-9]+)\r?\n([\s\S]*?)\r?\n\2\r?$')
    $values = @{}
    foreach ($record in $records) { $values[$record.Groups[1].Value] = $record.Groups[3].Value }
    Assert ($values['PKR_VAR_fixture'] -eq $env:PKR_VAR_fixture) 'multiline environment value changed'
    Assert (-not $values.ContainsKey('SECOND_VARIABLE')) 'environment value became an assignment'
    Assert ($values['PACKER_GITHUB_API_TOKEN'] -eq 'test-token') 'plugin token handoff lost'
    Assert ($values['PKR_VAR_config'] -eq 'win11-64-24h2') 'config handoff lost'
    foreach ($name in @('CONFIG','GITHUB_TOKEN','CLIENT_ID','OIDC_REQUEST_URL','OIDC_REQUEST_TOKEN','SUBSCRIPTION_ID','TENANT_ID','APPLICATION_ID')) {
        [Environment]::SetEnvironmentVariable($name, 'test')
    }
    $env:CONFIG = 'win11-64-24h2'
    & ./ci/prepare-azure-shared-worker-image.ps1
    Assert ((Get-Content $env:GITHUB_ENV) -contains "sharedimageversion=$env:PKR_VAR_sharedimage_version") 'artifact version lost'
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
} finally {
    Remove-Item Function:/az, Function:/packer -ErrorAction SilentlyContinue
    Remove-Item win11-64-24h2-replication.json -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $temp -Recurse -Force
}
Write-Host 'Image preparation checks passed.'
