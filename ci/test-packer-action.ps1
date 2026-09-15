$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Set-Location "$PSScriptRoot/.."
Import-Module powershell-yaml
$action = ConvertFrom-Yaml (Get-Content .github/actions/packer-build/action.yml -Raw)
$run = [scriptblock]::Create(($action.runs.steps | Where-Object { $_['id'] -eq 'packer' }).run)
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
$global:calls = @()
$global:failCommand = ''
function global:packer {
    $global:calls += ,$args
    $global:LASTEXITCODE = if ($args[0] -eq $global:failCommand) { 7 } else { 0 }
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path "$temp/template directory"
Set-Content "$temp/template with spaces.pkr.hcl" '# argument handling fixture'
try {
    foreach ($case in @(
        @('azure.pkr.hcl', 'azure-arm.sig', 'false'),
        @('gcp.pkr.hcl', 'googlecompute.example', 'true'),
        @('packer/tceng-aws.pkr.hcl', '', 'true'),
        @("$temp/template with spaces.pkr.hcl", 'name; throw "not code"', 'false'),
        @("$temp/template directory", '', 'false')
    )) {
        $env:PACKER_TEMPLATE, $env:PACKER_ONLY, $env:PACKER_FORCE = $case
        $global:calls = @()
        & $run
        Assert (($global:calls | ForEach-Object { $_[0] }) -join ',' -eq 'init,validate,build') 'Packer command order changed'
        $path = (Resolve-Path -LiteralPath $env:PACKER_TEMPLATE).Path
        foreach ($call in $global:calls) { Assert ($call[-1] -eq $path) 'template path was split or changed' }
        foreach ($call in $global:calls[1..2]) {
            Assert (($call -contains "-only=$env:PACKER_ONLY") -eq [bool]$env:PACKER_ONLY) 'selector changed'
        }
        Assert (($global:calls[2] -contains '-force') -eq ($env:PACKER_FORCE -eq 'true')) 'force changed'
    }
    $env:PACKER_TEMPLATE = 'azure.pkr.hcl'
    foreach ($command in @('init', 'validate', 'build')) {
        $global:failCommand = $command
        $global:calls = @()
        $failed = $false
        try { & $run } catch { $failed = $true }
        Assert $failed "Packer $command failure was hidden"
        Assert ($global:calls[-1][0] -eq $command) 'Packer continued after failure'
    }
    $global:failCommand = ''
    foreach ($case in @(@('', 'false'), @('missing-template.pkr.hcl', 'false'), @('azure.pkr.hcl', 'invalid'))) {
        $env:PACKER_TEMPLATE, $env:PACKER_FORCE = $case
        $global:calls = @()
        $failed = $false
        try { & $run } catch { $failed = $true }
        Assert ($failed -and $global:calls.Count -eq 0) 'invalid inputs reached Packer'
    }
} finally {
    Remove-Item Function:/packer
    Remove-Item -LiteralPath $temp -Recurse -Force
}
$global:LASTEXITCODE = 0 # Expected native failures above must not fail the GitHub shell wrapper.
Write-Host 'Generic Packer action checks passed.'
