$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function Read-Ast($Path) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $Path), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw $errors[0] }
    return $ast
}
$deploy = Read-Ast 'provisioners/windows/MDC1Windows/OS-deploy.ps1'
$update = $deploy.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Update-GetBoot' }, $true)
Invoke-Expression $update.Extent.Text
$template = [IO.File]::ReadAllText((Join-Path $root 'provisioners/windows/MDC1Windows/Get-Bootstrap.ps1'))
function Test-Path { return $false }
function Invoke-DownloadWithRetry { }
function Get-Content { return $script:template }
function Set-Content { param($Path, $Value) $script:rendered = $Value }
$local_scripts = 'test/'
$WorkerPool = 'win11-64-24h2-hw'; $role = 'win116424h2hw'
$src_Organisation = 'mozilla-platform-ops'; $src_Repository = 'ronin_puppet'; $src_Branch = 'master'
$hash = 'abcdef1'; $secret_date = '2026-11-06'; $puppet_version = '8.10.0'; $openvox_version = '8.19.2'; $git_version = '2.50.0'
function New-ItemProperty {
    param($Path, $Name, $Value, $PropertyType, [switch]$Force)
    $script:written = $Value
}
function Render-Deployment($PoolConfig) {
    $pool = $PoolConfig
    Update-GetBoot -revision ('a' * 40) 6>$null | Out-Null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($script:rendered, [ref]$null, [ref]$null)
    $write = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.Extent.Text -match 'New-ItemProperty.*-Name fleetbench_deployment ' }, $true)
    if (-not $write -or $script:rendered.Contains('FleetbenchDeploymentPlaceholder')) { throw 'Deployment token was not rendered' }
    Invoke-Expression $write.Extent.Text
    return $script:written
}
if ((Render-Deployment @{}) -ne '') { throw 'Absent key enabled the override' }
$first = Render-Deployment @{ fleetbench_on_deploy = $true }
$second = Render-Deployment @{ fleetbench_on_deploy = $true }
if (-not [guid]::Parse($first) -or $first -eq $second) { throw 'Deployment tokens must be fresh for every deploy' }
if (-not [guid]::Parse((Render-Deployment @{ fleetbench_on_deploy = $false }))) { throw 'Key presence must enable override' }

# Run the actual retry cleanup against real files in a disposable directory.
$bootstrap = Read-Ast 'provisioners/windows/MDC1Windows/bootstrap.ps1'
$retryCleanup = $bootstrap.Find({ param($n) $n -is [System.Management.Automation.Language.PipelineAst] -and $n.Extent.Text.StartsWith("Get-ChildItem -LiteralPath 'D:\'") }, $true)
$resyncCleanup = $deploy.Find({ param($n) $n -is [System.Management.Automation.Language.PipelineAst] -and $n.Extent.Text.StartsWith('Get-ChildItem -LiteralPath $local_install') }, $true)
if (-not $retryCleanup -or -not $resyncCleanup) { throw 'Deployment cleanup not found' }
$dir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
try {
    foreach ($cleanup in @($retryCleanup, $resyncCleanup)) {
        New-Item -ItemType Directory -Path (Join-Path $dir 'fleetbench/results'), (Join-Path $dir 'secrets') -Force | Out-Null
        # Bypass the rendering mock for real file IO.
        Microsoft.PowerShell.Management\Set-Content (Join-Path $dir 'fleetbench/results/prior_cpu.json') '{}'
        Microsoft.PowerShell.Management\Set-Content (Join-Path $dir 'secrets/pat.txt') 'test secret'
        Microsoft.PowerShell.Management\Set-Content (Join-Path $dir 'stale.txt') 'stale'
        $local_install = $dir
        Invoke-Expression ($cleanup.Extent.Text.Replace("'D:\'", "'$dir'"))
        if (-not [IO.File]::Exists((Join-Path $dir 'fleetbench/results/prior_cpu.json'))) { throw 'Retry deleted benchmark history' }
        if ([IO.Directory]::Exists((Join-Path $dir 'secrets')) -or [IO.File]::Exists((Join-Path $dir 'stale.txt'))) { throw 'Deployment did not clear provisioning files' }
    }
}
finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host 'Fleetbench deployment rendering and persistence checks passed.'
