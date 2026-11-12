$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$envNames = @('CONFIG', 'BUILD_DATE', 'GITHUB_OUTPUT', 'RUN_OS_INTEGRATION')
$saved = @{}
foreach ($name in $envNames) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
$temp = Join-Path ([IO.Path]::GetTempPath()) "gcp-config-matrices-$([guid]::NewGuid().ToString('N'))"

function Invoke-MatrixStep {
    param(
        [scriptblock] $Script,
        [string] $Config,
        [bool] $RunOsIntegration = $false,
        [string] $BuildDate = ''
    )

    $outputPath = Join-Path $temp "$([guid]::NewGuid().ToString('N')).txt"
    $env:CONFIG = $Config
    $env:RUN_OS_INTEGRATION = $RunOsIntegration.ToString().ToLowerInvariant()
    $env:BUILD_DATE = $BuildDate
    $env:GITHUB_OUTPUT = $outputPath
    & $Script

    $lines = Get-Content $outputPath
    $matrix = ($lines | Where-Object { $_.StartsWith('matrix=') } | Select-Object -Last 1).Substring('matrix='.Length) | ConvertFrom-Json -AsHashtable
    $osLine = $lines | Where-Object { $_.StartsWith('os_integration_matrix=') } | Select-Object -Last 1
    $osMatrix = if ($osLine) { $osLine.Substring('os_integration_matrix='.Length) | ConvertFrom-Json -AsHashtable } else { @{ config = @() } }
    [pscustomobject]@{
        Configs = @($matrix.config)
        OsIntegrationConfigs = @($osMatrix.config)
        BuildDate = $lines | Where-Object { $_.StartsWith('build_date=') } | Select-Object -Last 1
    }
}

function Assert-Items {
    param([string[]] $Actual, [string[]] $Expected, [string] $Description)
    if (@(Compare-Object $Expected $Actual).Count -gt 0) {
        throw "Unexpected $Description."
    }
}

Push-Location $repo
try {
    Import-Module ./bin/WorkerImages/WorkerImages.psm1 -Force
    $availableConfigs = @(
        Get-ChildItem ./config -File -Filter '*.yaml' |
            ForEach-Object { $_.BaseName } |
            Where-Object { $_ -match '^(trusted-)?gw-fxci-gcp-.*-alpha$' } |
            Sort-Object
    )
    $untrustedConfigs = @($availableConfigs | Where-Object { $_ -notmatch '^trusted-' })
    $trustedConfig = $availableConfigs | Where-Object { $_ -match '^trusted-' } | Select-Object -First 1
    $selectedConfig = $untrustedConfigs[0]
    $null = New-Item -ItemType Directory -Path $temp

    foreach ($path in @('.github/workflows/gcp-deploy-parallel.yml', '.github/workflows/gcp-fxci-parallel-alpha.yml')) {
        $workflow = ConvertFrom-Yaml (Get-Content $path -Raw)
        $options = @($workflow.on.workflow_dispatch.inputs.config.options)
        if ($options -notcontains 'all' -or @($availableConfigs | Where-Object { $options -cnotcontains $_ }).Count -gt 0) {
            throw "Manual choices in $path must include all and every GCP alpha config."
        }
        $step = $workflow.jobs.'prepare-matrix'.steps | Where-Object id -eq 'set-matrix'
        $script = [scriptblock]::Create($step.run)

        $all = Invoke-MatrixStep -Script $script -Config 'all' -BuildDate '2026-11-10'
        Assert-Items $all.Configs $availableConfigs "$path all-image matrix"

        $single = Invoke-MatrixStep -Script $script -Config $selectedConfig -BuildDate '2026-11-10'
        Assert-Items $single.Configs @($selectedConfig) "$path single-image matrix"

        $env:CONFIG = 'not-a-production-config'
        $env:RUN_OS_INTEGRATION = 'false'
        $env:BUILD_DATE = '2026-11-10'
        $env:GITHUB_OUTPUT = Join-Path $temp "$([guid]::NewGuid().ToString('N')).txt"
        $rejected = $false
        try { & $script } catch { $rejected = $true }
        if (-not $rejected) { throw "Unknown configs must be rejected by $path." }

        if ($path -like '*gcp-deploy-parallel.yml') {
            if ($all.BuildDate -ne 'build_date=2026-11-10' -or $single.BuildDate -ne 'build_date=2026-11-10') {
                throw 'The shared GCP production build date was not preserved.'
            }
        } else {
            Assert-Items $all.OsIntegrationConfigs $untrustedConfigs 'all-image integration matrix'
            Assert-Items $single.OsIntegrationConfigs @() 'default single-image integration matrix'
            $withIntegration = Invoke-MatrixStep -Script $script -Config $selectedConfig -RunOsIntegration $true
            Assert-Items $withIntegration.OsIntegrationConfigs @($selectedConfig) 'opt-in integration matrix'
            $trustedWithIntegration = Invoke-MatrixStep -Script $script -Config $trustedConfig -RunOsIntegration $true
            Assert-Items $trustedWithIntegration.OsIntegrationConfigs @() 'trusted-image integration matrix'
        }
    }

    Write-Host 'GCP production and alpha matrix selection passed.'
} finally {
    Pop-Location
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    if (Test-Path $temp) { Remove-Item $temp -Recurse -Force }
}
