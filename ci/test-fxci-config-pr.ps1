$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "fxci-config-pr-test-$([guid]::NewGuid().ToString('N'))"
$envNames = @(
    'FXCI_CONFIG_GITHUB_TOKEN', 'FXCI_TEST_CONFIG_REPO', 'GIT_CONFIG_COUNT',
    'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0', 'GIT_AUTHOR_DATE', 'GIT_COMMITTER_DATE'
)
$saved = @{}
foreach ($name in $envNames) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
$failures = [System.Collections.Generic.List[string]]::new()

$global:FxciTestWindows = @(
    @{ config = 'win10-64-2009'; image = 'ronin_t_windows10_64_2009_prod'; provider = 'azure2' }
    @{ config = 'win11-64-25h2'; image = 'win116425h2'; provider = 'azure2' }
    @{ config = 'win11-a64-25h2-builder'; image = 'win11a6425h2builder'; provider = 'azure2' }
    @{ config = 'trusted-win11-a64-25h2-builder'; image = 'trusted_win11_a64_25h2_builder'; provider = 'azure_trusted' }
    @{ config = 'win11-a64-25h2-tester'; image = 'win11a6425h2tester'; provider = 'azure2' }
    @{ config = 'win2022-64-2009'; image = 'ronin_b1_windows2022_64_2009'; provider = 'azure2' }
    @{ config = 'trusted-win2022-64-2009'; image = 'ronin_b3_windows2022_64_2009'; provider = 'azure_trusted' }
)
$global:FxciTestPr = $null
$global:FxciTestPrCreateCalls = 0
$global:FxciTestPrEditCalls = 0
$global:FxciTestFailNextPrCreate = $false

function Invoke-TestGit {
    param([string[]] $Arguments)
    $output = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed ($LASTEXITCODE): $($output -join "`n")"
    }
    return ($output | ForEach-Object { [string] $_ }) -join "`n"
}

function Initialize-TestRemote {
    param([string] $RepoSlug, [string] $BarePath)
    $seed = Join-Path $tempRoot "seed-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path $seed -Force
    $null = Invoke-TestGit @('init', '--bare', $BarePath)
    $null = Invoke-TestGit @('init', $seed)
    $null = Invoke-TestGit @('-C', $seed, 'checkout', '-b', 'main')

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($image in $global:FxciTestWindows) {
        $lines.Add("$($image.image):")
        $lines.Add("  $($image.provider):")
        $lines.Add('    version: 2026.10.27')
        $lines.Add("    deployment_id: $('a' * 40)")
    }
    [IO.File]::WriteAllText((Join-Path $seed 'worker-images.yml'), ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    $null = Invoke-TestGit @('-C', $seed, 'add', 'worker-images.yml')
    $null = Invoke-TestGit @('-C', $seed, '-c', 'user.name=PR test', '-c', 'user.email=pr-test@example.invalid', 'commit', '-m', 'Initial image config')
    $null = Invoke-TestGit @('-C', $seed, 'remote', 'add', 'origin', $BarePath)
    $null = Invoke-TestGit @('-C', $seed, 'push', 'origin', 'main')
    $null = Invoke-TestGit @("--git-dir=$BarePath", 'symbolic-ref', 'HEAD', 'refs/heads/main')

    $env:FXCI_TEST_CONFIG_REPO = $RepoSlug
    $env:GIT_CONFIG_COUNT = '1'
    $env:GIT_CONFIG_KEY_0 = "url.file://${BarePath}.insteadOf"
    $env:GIT_CONFIG_VALUE_0 = "https://github.com/$RepoSlug.git"
    $global:FxciTestBare = $BarePath
    $global:FxciTestPr = $null
    $global:FxciTestPrCreateCalls = 0
    $global:FxciTestPrEditCalls = 0
    $global:FxciTestFailNextPrCreate = $false
}

function Get-TestRemoteHead {
    param([string] $BarePath, [string] $Branch)
    $output = & git "--git-dir=$BarePath" rev-parse --verify "refs/heads/$Branch" 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ([string]$output).Trim()
}

function Get-TestRemoteYaml {
    param([string] $BarePath, [string] $Branch)
    $output = & git "--git-dir=$BarePath" show "refs/heads/${Branch}:worker-images.yml" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Could not read worker-images.yml from $Branch." }
    return ($output -join "`n")
}

function global:gh {
    $arguments = @($args | ForEach-Object { [string] $_ })
    $global:LASTEXITCODE = 0

    if ($arguments[0] -eq 'run' -and $arguments[1] -eq 'view') {
        $runId = $arguments[2]
        $run = [ordered]@{
            databaseId = [long]$runId
            workflowName = 'FXCI - Azure Prod Parallel Images'
            status = 'completed'
            conclusion = 'success'
            jobs = @($global:FxciTestWindows | ForEach-Object { @{ name = "Build $($_.config)"; conclusion = 'success' } })
            url = "https://github.com/test/worker-images/actions/runs/$runId"
            headSha = '1111111111111111111111111111111111111111'
        }
        return (ConvertTo-Json -InputObject $run -Depth 8 -Compress)
    }

    if ($arguments[0] -eq 'run' -and $arguments[1] -eq 'download') {
        $directoryIndex = [Array]::IndexOf($arguments, '--dir')
        if ($directoryIndex -lt 0) { $global:LASTEXITCODE = 2; return 'Missing --dir.' }
        $destination = $arguments[$directoryIndex + 1]
        foreach ($image in $global:FxciTestWindows) {
            $artifactDirectory = Join-Path $destination "release-notes-$($image.config)"
            $null = New-Item -ItemType Directory -Path $artifactDirectory -Force
            $artifactPath = Join-Path $artifactDirectory "$($image.config)-2026.11.10.md"
            $notes = "- Config: $($image.config)`n- DeploymentId: $global:FxciTestDeploymentId`n"
            [IO.File]::WriteAllText($artifactPath, $notes, [Text.UTF8Encoding]::new($false))
        }
        return
    }

    if ($arguments[0] -eq 'api' -and $arguments[1] -match '/compare/') {
        return '{"status":"ahead","commits":[]}'
    }

    if ($arguments[0] -eq 'pr' -and $arguments[1] -eq 'list') {
        $headIndex = [Array]::IndexOf($arguments, '--head')
        $requestedHead = if ($headIndex -ge 0) { $arguments[$headIndex + 1] } else { '' }
        if ($global:FxciTestPr -and $global:FxciTestPr.headRefName -eq $requestedHead) {
            $items = @(@{
                number = $global:FxciTestPr.number
                url = $global:FxciTestPr.url
                state = $global:FxciTestPr.state
                headRefName = $global:FxciTestPr.headRefName
            })
        } else {
            $items = @()
        }
        return (ConvertTo-Json -InputObject $items -Depth 5 -Compress)
    }

    if ($arguments[0] -eq 'pr' -and $arguments[1] -eq 'edit') {
        $titleIndex = [Array]::IndexOf($arguments, '--title')
        $bodyIndex = [Array]::IndexOf($arguments, '--body-file')
        $global:FxciTestPr.title = $arguments[$titleIndex + 1]
        $global:FxciTestPr.body = [IO.File]::ReadAllText($arguments[$bodyIndex + 1])
        $global:FxciTestPrEditCalls++
        return
    }

    if ($arguments[0] -eq 'pr' -and $arguments[1] -eq 'create') {
        $headIndex = [Array]::IndexOf($arguments, '--head')
        $titleIndex = [Array]::IndexOf($arguments, '--title')
        $bodyIndex = [Array]::IndexOf($arguments, '--body-file')
        $branch = $arguments[$headIndex + 1]
        $global:FxciTestPrCreateCalls++
        if ($global:FxciTestFailNextPrCreate) {
            $global:FxciTestFailNextPrCreate = $false
            $global:LASTEXITCODE = 1
            return 'simulated gh pr create failure'
        }
        $global:FxciTestPr = [pscustomobject]@{
            number = 1
            url = "https://github.com/$($env:FXCI_TEST_CONFIG_REPO)/pull/1"
            state = 'OPEN'
            headRefName = $branch
            title = $arguments[$titleIndex + 1]
            body = [IO.File]::ReadAllText($arguments[$bodyIndex + 1])
        }
        return $global:FxciTestPr.url
    }

    $global:LASTEXITCODE = 2
    return "Unexpected gh command: $($arguments -join ' ')"
}

function Invoke-Deployment {
    param([string] $RunId)
    New-FxciConfigPullRequest -AzureRunId $RunId
}

function Assert-Deployment {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

try {
    $null = New-Item -ItemType Directory -Path $tempRoot -Force
    $env:FXCI_CONFIG_GITHUB_TOKEN = 'mock-token'
    $helper = [IO.File]::ReadAllText((Join-Path $repoRoot 'bin/WorkerImages/Public/New-FxciConfigPullRequest.ps1'))
    $oldTarget = "`$fxciConfigRepo = 'mozilla-releng/fxci-config'"
    $newTarget = '$fxciConfigRepo = $env:FXCI_TEST_CONFIG_REPO'
    if (-not $helper.Contains($oldTarget)) { throw 'Could not isolate the production target for the test.' }
    $helper = $helper.Replace($oldTarget, $newTarget)
    if ($helper.Contains($oldTarget)) { throw 'Production target remains in the test helper.' }
    . ([scriptblock]::Create($helper))

    # Existing PR: changed artifacts for the same date must update the branch before the body.
    $firstBare = Join-Path $tempRoot 'changed-input.git'
    Initialize-TestRemote -RepoSlug 'test/fxci-config-changed' -BarePath $firstBare
    $global:FxciTestDeploymentId = 'b' * 40
    $env:GIT_AUTHOR_DATE = '2026-11-10T00:00:00Z'
    $env:GIT_COMMITTER_DATE = '2026-11-10T00:00:00Z'
    $firstUrl = Invoke-Deployment -RunId '1001'
    $branch = 'deploy-fxci-images-windows-20261110'
    $firstHead = Get-TestRemoteHead -BarePath $firstBare -Branch $branch

    $global:FxciTestDeploymentId = 'c' * 40
    $env:GIT_AUTHOR_DATE = '2026-11-10T00:01:00Z'
    $env:GIT_COMMITTER_DATE = '2026-11-10T00:01:00Z'
    $secondUrl = Invoke-Deployment -RunId '1002'
    $secondHead = Get-TestRemoteHead -BarePath $firstBare -Branch $branch
    $branchYaml = Get-TestRemoteYaml -BarePath $firstBare -Branch $branch
    try {
        Assert-Deployment ($firstUrl -eq $secondUrl) 'Changed-input rerun returned a different PR.'
        Assert-Deployment ($firstHead -ne $secondHead) 'Changed-input rerun did not update the existing branch.'
        Assert-Deployment ($branchYaml.Contains("deployment_id: $('c' * 7)")) 'Existing PR branch still has the old deployment ID.'
        Assert-Deployment ($global:FxciTestPr.body.Contains('run 1002')) 'Existing PR body was not refreshed.'
        Assert-Deployment ($global:FxciTestPr.body.Contains('ccccccc')) 'PR body does not match the updated deployment ID.'
        Assert-Deployment ($global:FxciTestPrCreateCalls -eq 1 -and $global:FxciTestPrEditCalls -eq 1) 'Expected one PR creation and one PR edit.'
        Write-Host 'Changed-input PR branch update passed.'
    } catch { $failures.Add("Changed-input PR branch update: $_") }

    # Partial success: push succeeds, PR creation fails, then a retry must reuse that remote branch.
    $secondBare = Join-Path $tempRoot 'retry.git'
    Initialize-TestRemote -RepoSlug 'test/fxci-config-retry' -BarePath $secondBare
    $global:FxciTestDeploymentId = 'd' * 40
    $global:FxciTestFailNextPrCreate = $true
    $env:GIT_AUTHOR_DATE = '2026-11-10T00:02:00Z'
    $env:GIT_COMMITTER_DATE = '2026-11-10T00:02:00Z'
    $failedAsExpected = $false
    try { $null = Invoke-Deployment -RunId '2001' } catch { $failedAsExpected = $true }
    $retryBranch = 'deploy-fxci-images-windows-20261110'
    $headAfterFailedCreate = Get-TestRemoteHead -BarePath $secondBare -Branch $retryBranch
    try {
        Assert-Deployment $failedAsExpected 'The simulated PR-create failure did not fail the first attempt.'
        Assert-Deployment ($headAfterFailedCreate -ne $null) 'The test did not reproduce a pushed branch without a PR.'
        $env:GIT_AUTHOR_DATE = '2026-11-10T00:03:00Z'
        $env:GIT_COMMITTER_DATE = '2026-11-10T00:03:00Z'
        $retryUrl = Invoke-Deployment -RunId '2001'
        $headAfterRetry = Get-TestRemoteHead -BarePath $secondBare -Branch $retryBranch
        Assert-Deployment ($headAfterRetry -eq $headAfterFailedCreate) 'Retry replaced the already-pushed branch commit.'
        Assert-Deployment ($retryUrl -eq $global:FxciTestPr.url) 'Retry did not create a PR for the existing branch.'
        Assert-Deployment ($global:FxciTestPrCreateCalls -eq 2) 'Expected one failed and one successful PR-create request.'
        Write-Host 'Push-success/PR-create-failure retry passed.'
    } catch { $failures.Add("Push-success/PR-create-failure retry: $_") }

    if ($failures.Count -gt 0) {
        throw ($failures -join "`n")
    }
    Write-Host 'FXCI config PR repeatability tests passed.'
} finally {
    Remove-Item Function:\gh -ErrorAction SilentlyContinue
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    foreach ($name in @('FxciTestWindows', 'FxciTestPr', 'FxciTestPrCreateCalls', 'FxciTestPrEditCalls', 'FxciTestFailNextPrCreate', 'FxciTestDeploymentId', 'FxciTestBare')) {
        Remove-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue
    }
    if (Test-Path $tempRoot) { Remove-Item $tempRoot -Recurse -Force }
}
