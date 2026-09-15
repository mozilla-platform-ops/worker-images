$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Set-Location "$PSScriptRoot/.."
Import-Module powershell-yaml
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
$workflow = ConvertFrom-Yaml (Get-Content .github/workflows/build-azure-image.yml -Raw)
Assert ($workflow.on.workflow_call.inputs.trusted.default -eq $false) 'untrusted must remain the default'
$steps = $workflow.jobs.build.steps
Assert (($steps | Where-Object { $_['id'] -eq 'access' }).run -match 'ci/check-authorized-user.ps1') 'shared build must enforce RelSRE authorization'
$ids = @($steps | ForEach-Object { $_['id'] })
Assert ($ids.IndexOf('access') -lt $ids.IndexOf('config') -and $ids.IndexOf('config') -lt $ids.IndexOf('login')) 'authorization and trust validation must precede Azure login'
Assert ($workflow.jobs.build.name -eq 'Packer') 'job-name contract with successful-build filtering changed'
Assert ($workflow.permissions.contents -eq 'read' -and $workflow.permissions['id-token'] -eq 'write') 'build permissions changed'
$validate = [scriptblock]::Create(($steps | Where-Object { $_['id'] -eq 'config' }).run.Replace('${{ github.workspace }}', (Get-Location).Path))
foreach ($case in @(
    @('win11-64-24h2', 'false', $true),
    @('trusted-win2025-64-24h2', 'true', $true),
    @('trusted-win2025-64-24h2', 'false', $false),
    @('win11-64-24h2', 'true', $false),
    @('../README', 'false', $false)
)) {
    $env:CONFIG, $env:TRUSTED_IMAGE, $expected = $case
    $passed = $true
    try { & $validate } catch { $passed = $false }
    Assert ($passed -eq $expected) "unexpected trust/config validation: $($case[0]) / $($case[1])"
}
$callers = @(
    'sig-nontrusted.yml', 'sig-trusted.yml',
    'sig-FXCI-nontrusted-parallel-build-alpha.yml', 'sig-FXCI-parallel-build.yml'
)
foreach ($name in $callers) {
    $caller = ConvertFrom-Yaml (Get-Content ".github/workflows/$name" -Raw)
    $build = $caller.jobs.packer
    Assert ($build.uses -eq './.github/workflows/build-azure-image.yml') "duplicated Azure build in $name"
    Assert (-not $build.ContainsKey('steps')) 'caller must delegate the whole build job'
    Assert ($build.secrets.Count -eq 4) 'pass only the four selected Azure secrets, not secrets: inherit'
    if ($name -eq 'sig-trusted.yml') {
        Assert ($build.with.trusted -eq $true) 'trusted entrypoint lost its restriction'
        Assert ($build.secrets['subscription-id'] -eq '${{ secrets.AZURE_SUBSCRIPTION_ID_TRUSTED }}') 'trusted subscription lost'
    } elseif ($name -ne 'sig-FXCI-parallel-build.yml') {
        Assert (-not $build.with.ContainsKey('trusted')) 'untrusted entrypoint must use the false default'
        Assert ($build.secrets['subscription-id'] -eq '${{ secrets.AZURE_SUBSCRIPTION_ID_UNTRUSTED }}') 'untrusted subscription lost'
    } else {
        Assert ($build.with.trusted -eq '${{ startsWith(matrix.config, ''trusted-'') }}') 'production trust selection lost'
        Assert ($build.secrets['subscription-id'] -eq '${{ secrets[matrix.subscription_id_secret] }}') 'production credentials no longer follow the matrix'
    }
}
$replication = @($steps | Where-Object { $_['name'] -eq 'Upload replication request' })
if ($replication.Count) {
    Assert ($replication[0]['if'] -eq '${{ success() && inputs.defer-replication }}') 'replication request must only upload after a successful build'
    $production = ConvertFrom-Yaml (Get-Content .github/workflows/sig-FXCI-parallel-build.yml -Raw)
    Assert ($production.jobs.packer.with['defer-replication'] -eq $true) 'production deferral lost'
    Assert ($production.jobs['os-integration'].needs -contains 'replicate') 'production integration bypasses replication'
}
Write-Host 'Shared Azure workflow checks passed.'
