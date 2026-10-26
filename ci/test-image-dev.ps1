$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repo = Split-Path $PSScriptRoot
Import-Module "$repo/bin/WorkerImages"
$root = Join-Path ([IO.Path]::GetTempPath()) ('image-dev-test-' + [guid]::NewGuid())
$saved = @{}
foreach ($name in @('GITHUB_ACTOR', 'GITHUB_TRIGGERING_ACTOR', 'GITHUB_OUTPUT')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
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
    $null = New-Item -ItemType Directory -Path "$root/origin/config", "$root/origin/.github" -Force
    Push-Location "$root/origin"
    git init -q -b main
    git config user.name Test
    git config user.email test@example.invalid
    '["relops-test"]' | Set-Content .github/relsre.json
    Copy-Item "$repo/config/win11-64-25h2-alpha.yaml", "$repo/config/windows_production_defaults.yaml", "$repo/config/gw-fxci-gcp-l1-2404-headless-alpha.yaml" config
    Commit
    git checkout -q -b dev/test
    $gcpKey = 'gw-fxci-gcp-l1-2404-headless-alpha'
    Set-YamlValue "config/$gcpKey.yaml" image_name selected-branch-alpha
    '["attacker"]' | Set-Content .github/relsre.json
    Commit
    $pin = git rev-parse HEAD
    Pop-Location
    git clone -q --branch main "$root/origin" "$root/trusted"
    Push-Location "$root/trusted"
    $env:GITHUB_OUTPUT = "$root/outputs"
    $env:GITHUB_ACTOR = 'relops-test'; $env:GITHUB_TRIGGERING_ACTOR = ''
    $prepare = "$repo/ci/prepare-image-dev.ps1"
    & $prepare -Branch dev/test -Key $gcpKey -Provider GCP
    $outputs = Get-Content $env:GITHUB_OUTPUT -Raw | ConvertFrom-StringData
    if ($outputs.revision -ne $pin -or $outputs.notes -ne 'sboms/selected-branch-alpha.md') { throw 'Wrong revision or selected config.' }
    if ((git rev-parse --abbrev-ref HEAD) -ne 'main' -or @(git worktree list).Count -ne 1) { throw 'Preparation changed the checkout or created a worktree.' }
    Clear-Content $env:GITHUB_OUTPUT
    & $prepare -Branch dev/test -Key win11-64-25h2-alpha -Provider Azure
    $outputs = Get-Content $env:GITHUB_OUTPUT -Raw | ConvertFrom-StringData
    if ($outputs.notes -notmatch '^win11-64-25h2-alpha-\d+\.\d+\.\d+\.md$') { throw 'Wrong Azure notes path.' }
    $env:GITHUB_ACTOR = 'attacker'
    Reject { & $prepare -Branch 'bad branch' -Key $gcpKey -Provider GCP } 'Not authorized'
    $env:GITHUB_ACTOR = 'relops-test'; $env:GITHUB_TRIGGERING_ACTOR = 'attacker'
    Reject { & $prepare -Branch dev/test -Key $gcpKey -Provider GCP } 'Not authorized'
    $env:GITHUB_TRIGGERING_ACTOR = ''
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
    # Exercise the workflow's actual retry loop for exceptions, exit codes, and exhaustion.
    foreach ($provider in @('Azure', 'GCP')) {
        $workflow = ConvertFrom-Yaml (Get-Content "$repo/.github/workflows/image-dev-$($provider.ToLower()).yml" -Raw)
        $job = $workflow.jobs.build
        $steps = @($job.steps)
        if ($job.if -ne "github.ref == 'refs/heads/main'" -or
            $steps[0].with.ref -ne 'main' -or $job.permissions.contents -ne 'read' -or
            $steps[1].name -ne 'Authorize and pin development branch' -or
            $steps[1].run -notlike "*-Provider $provider*" -or
            $steps[2].with.ref -ne '${{ steps.source.outputs.revision }}') {
            throw 'Workflow must authorize from main before checking out the pinned source with a read-only repository token.'
        }
        if ($provider -eq 'Azure') { $azureWorkflow = $workflow } else { $gcpWorkflow = $workflow }
    }
    if (($gcpWorkflow.jobs.build.steps | Where-Object name -eq 'GCP login').with.service_account -ne 'deploy-prod@taskcluster-imaging.iam.gserviceaccount.com' -or
        ($azureWorkflow.jobs.build.steps | Where-Object name -eq 'Azure login').with.'subscription-id' -ne '${{ secrets.AZURE_SUBSCRIPTION_ID_UNTRUSTED }}') {
        throw 'Development workflow must use the non-trusted cloud identities.'
    }
    $run = ($azureWorkflow.jobs.build.steps | Where-Object name -eq 'Build selected revision').run
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
