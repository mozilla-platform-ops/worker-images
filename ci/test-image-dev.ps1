$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repo = Split-Path $PSScriptRoot
Import-Module "$repo/bin/WorkerImages"
$root = Join-Path ([IO.Path]::GetTempPath()) ('image-dev-test-' + [guid]::NewGuid())
$saved = @{}
foreach ($name in @('GITHUB_OUTPUT')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
function Reject {
    param([scriptblock] $Action, [string] $Message)
    try { & $Action } catch {
        if ($_ -notlike "*$Message*") { throw "Expected '$Message', got $_" }
        return
    }
    throw "Expected rejection: $Message"
}
function Set-YamlValue {
    param([string] $Path, [string] $Name, [string] $Value)
    # Each fixture key is on one line, so a line replace needs no YAML writer.
    (Get-Content $Path -Raw) -replace "(?m)^(\s*$Name):.*$", "`$1: $Value" | Set-Content $Path -NoNewline
}
function Commit {
    git add .
    git commit -qm fixture
}
try {
    $null = New-Item -ItemType Directory -Path "$root/origin/config" -Force
    Push-Location "$root/origin"
    git init -q -b main
    git config user.name Test
    git config user.email test@example.invalid
    Copy-Item "$repo/config/win11-64-25h2-alpha.yaml", "$repo/config/windows_production_defaults.yaml", "$repo/config/gw-fxci-gcp-l1-2404-headless-alpha.yaml" config
    Commit
    git checkout -q -b dev/test
    $gcpKey = 'gw-fxci-gcp-l1-2404-headless-alpha'
    Set-YamlValue "config/$gcpKey.yaml" image_name selected-branch-alpha
    Commit
    $pin = git rev-parse HEAD
    Pop-Location
    git clone -q --branch main "$root/origin" "$root/trusted"
    Push-Location "$root/trusted"
    $env:GITHUB_OUTPUT = "$root/outputs"
    $prepare = "$repo/ci/prepare-image-dev.ps1"
    & $prepare -Branch dev/test -Key $gcpKey -Provider GCP
    $outputs = Get-Content $env:GITHUB_OUTPUT -Raw | ConvertFrom-StringData
    if ($outputs.revision -ne $pin -or $outputs.notes -ne 'sboms/selected-branch-alpha.md') { throw 'Wrong revision or selected config.' }
    if ((git rev-parse --abbrev-ref HEAD) -ne 'main' -or @(git worktree list).Count -ne 1) { throw 'Preparation changed the checkout or created a worktree.' }
    Clear-Content $env:GITHUB_OUTPUT
    & $prepare -Branch dev/test -Key win11-64-25h2-alpha -Provider Azure
    $outputs = Get-Content $env:GITHUB_OUTPUT -Raw | ConvertFrom-StringData
    if ($outputs.notes -notmatch '^win11-64-25h2-alpha-\d+\.\d+\.\d+\.md$') { throw 'Wrong Azure notes path.' }
    Reject { & $prepare -Branch 'bad branch' -Key $gcpKey -Provider GCP } 'git'
    foreach ($key in @('../other-alpha', 'tceng/other-alpha', 'production', 'trusted-gcp-alpha')) {
        Reject { & $prepare -Branch dev/test -Key $key -Provider GCP } 'Not authorized'
    }
    Reject { & $prepare -Branch missing -Key $gcpKey -Provider GCP } 'git'
    foreach ($mutation in @('l3', 'production', 'azure', 'link')) {
        Push-Location "$root/origin"
        git checkout -q -B "bad/$mutation" $pin
        if ($mutation -eq 'l3') { Set-YamlValue "config/$gcpKey.yaml" project_id fxci-production-level3-workers }
        if ($mutation -eq 'production') { Set-YamlValue "config/$gcpKey.yaml" image_name production }
        if ($mutation -eq 'azure') { Set-YamlValue config/win11-64-25h2-alpha.yaml gallery_name production }
        if ($mutation -eq 'link') { $null = New-Item -ItemType SymbolicLink escape -Target /tmp }
        Commit
        Pop-Location
        if ($mutation -eq 'azure') {
            Reject { & $prepare -Branch "bad/$mutation" -Key win11-64-25h2-alpha -Provider Azure } 'alpha Azure'
        } else {
            Reject { & $prepare -Branch "bad/$mutation" -Key $gcpKey -Provider GCP } $(if ($mutation -eq 'link') { 'symbolic links' } else { 'non-trusted' })
        }
    }
    # Exercise the shared workflow's trusted checkout and Azure retry loop.
    $workflow = ConvertFrom-Yaml (Get-Content "$repo/.github/workflows/image-dev.yml" -Raw)
    $job = $workflow.jobs.build
    $steps = @($job.steps)
    $providerOptions = @($workflow.on.workflow_dispatch.inputs.provider.options)
    $azureLogin = $steps | Where-Object name -eq 'Azure login'
    $gcpLogin = $steps | Where-Object name -eq 'GCP login'
    $azureBuild = $steps | Where-Object name -eq 'Build selected revision - Azure'
    $gcpBuild = $steps | Where-Object name -eq 'Build selected revision - GCP'
    if ($job.if -ne "github.ref == 'refs/heads/main'" -or
        $job.permissions.contents -ne 'read' -or
        $steps[0].with.ref -ne 'main' -or
        $steps[0].with.path -ne 'trusted' -or
        $steps[1].uses -ne './trusted/.github/actions/check-workerimages-user-authorization' -or
        $steps[2].name -ne 'Authorize and pin development branch' -or
        $steps[2].env.DEV_PROVIDER -ne '${{ inputs.provider }}' -or
        $steps[2].run -notlike '*-Provider $env:DEV_PROVIDER*' -or
        $steps[3].with.ref -ne '${{ steps.source.outputs.revision }}' -or
        $providerOptions -notcontains 'Azure' -or $providerOptions -notcontains 'GCP') {
        throw 'Workflow must authorize from main before checking out the pinned source with a read-only repository token.'
    }
    if ($azureLogin.if -ne "inputs.provider == 'Azure'" -or
        $azureLogin.with.'subscription-id' -ne '${{ secrets.AZURE_SUBSCRIPTION_ID_UNTRUSTED }}' -or
        $gcpLogin.if -ne "inputs.provider == 'GCP'" -or
        $gcpLogin.with.service_account -ne 'deploy-prod@taskcluster-imaging.iam.gserviceaccount.com' -or
        $azureBuild.if -ne "inputs.provider == 'Azure'" -or
        $gcpBuild.if -ne "inputs.provider == 'GCP'" -or
        $gcpBuild.run -notlike '*New-GCPWorkerImage*') {
        throw 'Development workflow must use provider-matched non-trusted cloud identities and build steps.'
    }
    $run = $azureBuild.run
    $loop = [regex]::Match($run, '(?s)for \(\$attempt.*').Value
    if (-not $loop) { throw 'Retry loop not found.' }
    $retry = [scriptblock]::Create($loop)
    function New-AzSharedWorkerImage {
        $script:attempts++
        $global:LASTEXITCODE = 0
        if ($script:attempts -eq 1 -or $script:failure -eq 'persistent') {
            if ($script:failure -eq 'exit') { $global:LASTEXITCODE = 7 } else { throw 'Transient Packer failure' }
        }
    }
    function Start-Sleep { }
    $vars = @{}
    foreach ($failure in @('exception', 'exit', 'persistent')) {
        $script:failure = $failure; $script:attempts = 0
        if ($failure -eq 'persistent') { Reject { & $retry } 'Transient Packer failure' } else { & $retry }
        if ($attempts -ne $(if ($failure -eq 'persistent') { 10 } else { 2 })) { throw 'Wrong retry count.' }
    }
    Write-Host 'Development workflow authorization, pins, destination validation, and retries passed.'
} finally {
    while ((Get-Location).Path.StartsWith($root)) { Pop-Location }
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    if (Test-Path $root) { Remove-Item $root -Recurse -Force }
}
