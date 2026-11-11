function New-FxciConfigPullRequest {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param (
        [ValidatePattern('^\d+$')]
        [string] $AzureRunId,

        [ValidatePattern('^\d+$')]
        [string] $GcpRunId
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if (-not $AzureRunId -and -not $GcpRunId) {
        throw 'Pass at least one of -AzureRunId or -GcpRunId.'
    }

    $workerImagesRepo = 'mozilla-platform-ops/worker-images'
    $fxciConfigRepo = 'mozilla-releng/fxci-config'
    $fxciConfigToken = $env:FXCI_CONFIG_GITHUB_TOKEN
    $roninPuppetRepo = 'mozilla-platform-ops/ronin_puppet'
    $windowsPuppetFilePattern = '(?i)^(data/os/windows\.yaml|data/roles/[^/]*win[^/]*\.ya?ml|modules/win[^/]+/.*|modules/roles_profiles/manifests/roles/[^/]*win[^/]*\.pp|modules/roles_profiles/manifests/profiles/(chocolatey|disable_services|git)\.pp|test/integration/windows/.*|test/windows/.*|test/test_[^/]*windows[^/]*|test/test_windows[^/]*|\.kitchen/provision_windows\.ps1)$'
    $windowsImages = @{
        'win10-64-2009' = @{ image = 'ronin_t_windows10_64_2009_prod'; provider = 'azure2' }
        'win11-64-25h2' = @{ image = 'win116425h2'; provider = 'azure2' }
        'win11-a64-25h2-builder' = @{ image = 'win11a6425h2builder'; provider = 'azure2' }
        'trusted-win11-a64-25h2-builder' = @{ image = 'trusted_win11_a64_25h2_builder'; provider = 'azure_trusted' }
        'win11-a64-25h2-tester' = @{ image = 'win11a6425h2tester'; provider = 'azure2' }
        'win2022-64-2009' = @{ image = 'ronin_b1_windows2022_64_2009'; provider = 'azure2' }
        'trusted-win2022-64-2009' = @{ image = 'ronin_b3_windows2022_64_2009'; provider = 'azure_trusted' }
    }
    $ignoredWindowsImages = @('win2025-64-24h2', 'trusted-win2025-64-24h2')
    $gcpImages = @(
        @{ pattern = '^gw-fxci-gcp-l1-2404-amd64-gui-googlecompute-(?<date>\d{4}-\d{2}-\d{2})$'; image = 'ubuntu-2404-wayland'; provider = 'fxci-level1-gcp'; project = 'taskcluster-imaging' }
        @{ pattern = '^gw-fxci-gcp-l1-2404-amd64-headless-googlecompute-(?<date>\d{4}-\d{2}-\d{2})$'; image = 'ubuntu-2404-headless'; provider = 'fxci-level1-gcp'; project = 'taskcluster-imaging' }
        @{ pattern = '^gw-fxci-gcp-l3-2404-amd64-headless-googlecompute-(?<date>\d{4}-\d{2}-\d{2})$'; image = 'ubuntu-2404-headless'; provider = 'fxci-level3-gcp'; project = 'fxci-production-level3-workers' }
        @{ pattern = '^gw-fxci-gcp-l1-2404-arm64-headless-googlecompute-(?<date>\d{4}-\d{2}-\d{2})$'; image = 'ubuntu-2404-arm64-headless'; provider = 'fxci-level1-gcp'; project = 'taskcluster-imaging' }
        @{ pattern = '^gw-fxci-gcp-l3-2404-arm64-headless-googlecompute-(?<date>\d{4}-\d{2}-\d{2})$'; image = 'ubuntu-2404-arm64-headless'; provider = 'fxci-level3-gcp'; project = 'fxci-production-level3-workers' }
    )

    function Invoke-CheckedCommand {
        param([string] $FilePath, [string[]] $Arguments, [string] $GitHubToken)
        $previousGhToken = $env:GH_TOKEN
        try {
            if ($GitHubToken) { $env:GH_TOKEN = $GitHubToken }
            $output = & $FilePath @Arguments 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "$FilePath $($Arguments -join ' ') failed with exit code $LASTEXITCODE`n$($output -join "`n")"
            }
            return ($output | ForEach-Object { [string] $_ }) -join "`n"
        } finally {
            if ($null -eq $previousGhToken) {
                Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
            } else {
                $env:GH_TOKEN = $previousGhToken
            }
        }
    }

    function Get-WorkflowRun {
        param([string] $RunId, [ValidateSet('Azure', 'GCP')][string] $Platform)
        $json = Invoke-CheckedCommand 'gh' @(
            'run', 'view', $RunId, '--repo', $workerImagesRepo,
            '--json', 'databaseId,workflowName,status,conclusion,jobs,url,headSha'
        )
        $run = $json | ConvertFrom-Json
        $expectedWorkflows = if ($Platform -eq 'Azure') {
            @('Azure Prod Parallel', 'FXCI - Production Parallel Images')
        } else {
            @('GCP Prod Parallel', 'FXCI - Production Parallel Images')
        }
        if (-not ($expectedWorkflows | Where-Object { $run.workflowName -match [regex]::Escape($_) })) {
            throw "Run $RunId is '$($run.workflowName)', not an $Platform production parallel run."
        }
        # The final job runs before GitHub marks its parent workflow complete.
        $isCurrentUnifiedRun = $run.workflowName -eq 'FXCI - Production Parallel Images' -and
            $RunId -eq $env:GITHUB_RUN_ID
        if ($run.status -ne 'completed' -and
            -not ($isCurrentUnifiedRun -and $run.status -eq 'in_progress')) {
            throw "Run $RunId is not complete (status: $($run.status))."
        }
        return $run
    }

    function Assert-ImageJobSucceeded {
        param($Run, [string] $JobName, [string] $WorkflowJobName)
        $jobNamePattern = '(?:^| / )' + [regex]::Escape($JobName) + '$'
        $jobs = @($Run.jobs | Where-Object { $_.name -eq $JobName -or $_.name -match $jobNamePattern })
        if ($jobs.Count -eq 0 -and $Run.workflowName -eq 'FXCI - Production Parallel Images') {
            $workflowJobPattern = '(?:^| / )' + [regex]::Escape($WorkflowJobName) + '$'
            $jobs = @($Run.jobs | Where-Object { $_.name -eq $WorkflowJobName -or $_.name -match $workflowJobPattern })
        }
        if ($jobs.Count -ne 1 -or $jobs[0].conclusion -ne 'success') {
            $result = if ($jobs.Count -eq 1) { $jobs[0].conclusion } else { 'missing or duplicated' }
            throw "Image job '$JobName' in run $($Run.databaseId) did not succeed ($result)."
        }
    }

    function Get-SectionRange {
        param([string[]] $Lines, [string] $ImageKey)
        $header = [regex]::Escape($ImageKey) + ':\s*(?:#.*)?$'
        $starts = @(
            for ($i = 0; $i -lt $Lines.Count; $i++) {
                if ($Lines[$i] -match "^$header") { $i }
            }
        )
        if ($starts.Count -ne 1) {
            throw "Expected one '$ImageKey' section in worker-images.yml; found $($starts.Count)."
        }
        $start = $starts[0]
        $end = $Lines.Count
        for ($i = $start + 1; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i] -match '^[A-Za-z0-9_-]+:') {
                $end = $i
                break
            }
        }
        return @{ start = $start; end = $end }
    }

    function Get-WorkerImageFieldValue {
        param([string] $Content, [string] $ImageKey, [string] $Field)
        $lines = @($Content -split "\r?\n")
        $range = Get-SectionRange -Lines $lines -ImageKey $ImageKey
        $fieldPattern = '^([\t ]+)' + [regex]::Escape($Field) + ':\s*(\S+)(?:\s+#.*)?$'
        $fieldMatches = @(
            for ($i = $range.start + 1; $i -lt $range.end; $i++) {
                $match = [regex]::Match($lines[$i], $fieldPattern)
                if ($match.Success) { $match.Groups[2].Value }
            }
        )
        if ($fieldMatches.Count -ne 1) {
            throw "Expected one '$Field' value in '$ImageKey'; found $($fieldMatches.Count)."
        }
        return $fieldMatches[0]
    }

    function Get-UpdatedWorkerImagesYaml {
        param([string] $Content, [string] $ImageKey, [string] $Field, [string] $Value)
        $newline = if ($Content.Contains("`r`n")) { "`r`n" } else { "`n" }
        $lines = [System.Collections.Generic.List[string]]::new()
        foreach ($line in ($Content -split "\r?\n")) { $lines.Add($line) }
        $range = Get-SectionRange -Lines $lines.ToArray() -ImageKey $ImageKey
        $fieldPattern = '^([\t ]+)' + [regex]::Escape($Field) + ':\s*.*$'
        $fieldMatches = @(
            for ($i = $range.start + 1; $i -lt $range.end; $i++) {
                $match = [regex]::Match($lines[$i], $fieldPattern)
                if ($match.Success) { @{ index = $i; indent = $match.Groups[1].Value } }
            }
        )
        if ($fieldMatches.Count -ne 1) {
            throw "Expected one '$Field' field in '$ImageKey'; found $($fieldMatches.Count)."
        }
        $lines[$fieldMatches[0].index] = "$($fieldMatches[0].indent)${Field}: $Value"
        return [string]::Join($newline, $lines)
    }

    function Get-WindowsPuppetChangeMarkdown {
        param([object[]] $Ranges)
        $sections = [System.Collections.Generic.List[string]]::new()
        foreach ($range in $Ranges) {
            $compareUrl = "https://github.com/$roninPuppetRepo/compare/$($range.base)...$($range.head)"
            $compareJson = Invoke-CheckedCommand 'gh' @(
                'api', "repos/$roninPuppetRepo/compare/$($range.base)...$($range.head)"
            )
            $comparison = $compareJson | ConvertFrom-Json
            if ($comparison.status -notin @('ahead', 'identical')) {
                throw "Puppet compare $($range.base)...$($range.head) is '$($comparison.status)'; review the deployment base manually."
            }

            $rows = [System.Collections.Generic.List[string]]::new()
            foreach ($commit in @($comparison.commits)) {
                $files = Invoke-CheckedCommand 'gh' @(
                    'api', "repos/$roninPuppetRepo/commits/$($commit.sha)", '--jq', '.files[].filename'
                )
                if (-not ($files -split "\r?\n" | Where-Object { $_ -match $windowsPuppetFilePattern })) { continue }
                $shortSha = $commit.sha.Substring(0, 7)
                $subject = ($commit.commit.message -split "\r?\n", 2)[0].Replace('|', '\|')
                $rows.Add("| [$shortSha]($($commit.html_url)) | $subject |")
            }

            if ($rows.Count -eq 0) {
                $sections.Add("No Windows-specific Puppet changes in ``$($range.base)...$($range.head)``.")
                continue
            }
            $headShort = $range.head.Substring(0, 7)
            $sections.Add("## Windows Puppet commits (``$($range.base)...$headShort``)")
            $sections.Add('')
            $sections.Add('| Commit | Change |')
            $sections.Add('|---|---|')
            foreach ($row in $rows) { $sections.Add($row) }
            $sections.Add('')
            $sections.Add("[Full compare]($compareUrl)")
        }
        return $sections -join "`n"
    }

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) "fxci-image-deploy-$([guid]::NewGuid().ToString('N'))"
    $fxciPath = Join-Path $tempRoot 'fxci-config'
    $updates = [System.Collections.Generic.List[object]]::new()
    $windowsRun = $null
    $gcpRun = $null

    try {
        $null = New-Item -ItemType Directory -Path $tempRoot -Force -WhatIf:$false

        if ($AzureRunId) {
            $windowsRun = Get-WorkflowRun -RunId $AzureRunId -Platform Azure
            $null = New-Item -ItemType Directory -Path (Join-Path $tempRoot 'azure-artifacts') -Force -WhatIf:$false
            $null = Invoke-CheckedCommand 'gh' @(
                'run', 'download', $AzureRunId, '--repo', $workerImagesRepo,
                '--dir', (Join-Path $tempRoot 'azure-artifacts')
            )
            $files = @(
                Get-ChildItem -Path (Join-Path $tempRoot 'azure-artifacts') -Filter '*.md' -File -Recurse |
                    Where-Object { $_.Directory.Name -like 'release-notes-*' -and $_.Directory.Name -notlike 'release-notes-production-*' }
            )
            $found = @{}
            foreach ($file in $files) {
                $text = [IO.File]::ReadAllText($file.FullName)
                $configMatch = [regex]::Match($text, '(?m)^-\s+Config:\s*(\S+)\s*$')
                if (-not $configMatch.Success) { throw "No Windows image config in $($file.FullName)." }
                $config = $configMatch.Groups[1].Value
                if ($ignoredWindowsImages -contains $config) {
                    Write-Verbose "Leaving Windows Server 2025 unchanged: $config"
                    continue
                }
                if (-not $windowsImages.ContainsKey($config)) {
                    throw "No fxci-config mapping for Windows image '$config'. Update the explicit deployment map."
                }
                if ($found.ContainsKey($config)) { throw "Duplicate Windows image artifact for '$config'." }
                $found[$config] = $true

                $versionMatch = [regex]::Match($file.BaseName, '^(.+)-(\d{4}\.\d{2}\.\d{2})$')
                if (-not $versionMatch.Success -or $versionMatch.Groups[1].Value -ne $config) {
                    throw "Cannot read the Azure gallery version from artifact filename '$($file.Name)'."
                }
                $version = $versionMatch.Groups[2].Value
                $null = [DateTime]::ParseExact($version, 'yyyy.MM.dd', [Globalization.CultureInfo]::InvariantCulture)
                $buildDate = $version.Replace('.', '-')
                $deploymentMatch = [regex]::Match($text, '(?m)^-\s+DeploymentId:\s*([a-fA-F0-9]{7,40})\s*$')
                if (-not $deploymentMatch.Success) { throw "No valid DeploymentId in $($file.FullName)." }
                $deploymentIdFull = $deploymentMatch.Groups[1].Value.ToLowerInvariant()
                $deploymentId = $deploymentIdFull.Substring(0, 7)
                Assert-ImageJobSucceeded -Run $windowsRun -JobName "Build $config" -WorkflowJobName 'Azure Windows Production'
                $mapping = $windowsImages[$config]
                $updates.Add([pscustomobject]@{
                    platform = 'Windows'; config = $config; image = $mapping.image
                    provider = $mapping.provider; version = $version; buildDate = $buildDate
                    deploymentId = $deploymentId; deploymentIdFull = $deploymentIdFull
                    sbomUrl = "https://github.com/$workerImagesRepo/blob/main/sboms/$($file.Name)"
                })
            }
            $missing = @($windowsImages.Keys | Where-Object { -not $found.ContainsKey($_) })
            if ($missing.Count -gt 0) {
                throw "Azure run $AzureRunId is missing production artifacts for: $($missing -join ', ')."
            }
        }

        if ($GcpRunId) {
            $gcpRun = Get-WorkflowRun -RunId $GcpRunId -Platform GCP
            $null = New-Item -ItemType Directory -Path (Join-Path $tempRoot 'gcp-artifacts') -Force -WhatIf:$false
            $null = Invoke-CheckedCommand 'gh' @(
                'run', 'download', $GcpRunId, '--repo', $workerImagesRepo,
                '--dir', (Join-Path $tempRoot 'gcp-artifacts')
            )
            $files = @(
                Get-ChildItem -Path (Join-Path $tempRoot 'gcp-artifacts') -Filter '*.md' -File -Recurse |
                    Where-Object { $_.Directory.Name -like 'release-notes-production-*' }
            )
            $found = @{}
            foreach ($file in $files) {
                $config = $file.Directory.Name -replace '^release-notes-production-', ''
                if ($config -eq $file.Directory.Name) { throw "Unexpected GCP artifact directory '$($file.Directory.Name)'." }
                $text = [IO.File]::ReadAllText($file.FullName)
                $imageMatch = [regex]::Match($text, '(?m)^- Production image name:\s*`([^`]+)`\s*$')
                $projectMatch = [regex]::Match($text, '(?m)^- GCP project:\s*(\S+)\s*$')
                if (-not $imageMatch.Success -or -not $projectMatch.Success) {
                    throw "Missing production image name or GCP project in $($file.FullName)."
                }
                $imageName = $imageMatch.Groups[1].Value
                $mapping = @($gcpImages | Where-Object { $imageName -match $_.pattern })
                if ($mapping.Count -ne 1) { throw "No unique fxci-config mapping for GCP image '$imageName'." }
                $mapping = $mapping[0]
                if ($projectMatch.Groups[1].Value -ne $mapping.project) {
                    throw "GCP project mismatch for '$imageName': expected '$($mapping.project)', got '$($projectMatch.Groups[1].Value)'."
                }
                $key = "$($mapping.image)/$($mapping.provider)"
                if ($found.ContainsKey($key)) { throw "Duplicate GCP production artifact for '$key'." }
                $found[$key] = $true
                Assert-ImageJobSucceeded -Run $gcpRun -JobName "GCP $config" -WorkflowJobName 'GCP Linux Production'
                $date = [regex]::Match($imageName, $mapping.pattern).Groups['date'].Value
                $null = [DateTime]::ParseExact($date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
                $updates.Add([pscustomobject]@{
                    platform = 'Linux'; config = $config; image = $mapping.image
                    provider = $mapping.provider; buildDate = $date
                    reference = "projects/$($mapping.project)/global/images/$imageName"
                    sbomUrl = "https://github.com/$workerImagesRepo/blob/main/sboms/$($file.Name)"
                })
            }
            $expected = @($gcpImages | ForEach-Object { "$($_.image)/$($_.provider)" })
            $missing = @($expected | Where-Object { -not $found.ContainsKey($_) })
            if ($missing.Count -gt 0) {
                throw "GCP run $GcpRunId is missing production artifacts for: $($missing -join ', ')."
            }
        }

        $imageBuildDates = @($updates | ForEach-Object { $_.buildDate } | Sort-Object -Unique)
        if ($imageBuildDates.Count -eq 0) { throw 'No image build date was found for deployment PR.' }
        $deploymentDate = $imageBuildDates[-1].Replace('-', '.')
        $branchBuildDate = ($imageBuildDates | ForEach-Object { $_ -replace '-', '' }) -join '-'
        $branchPlatforms = @()
        if ($AzureRunId) { $branchPlatforms += 'windows' }
        if ($GcpRunId) { $branchPlatforms += 'linux' }
        $branch = "deploy-fxci-images-$($branchPlatforms -join '-')-$branchBuildDate"
        $existing = Invoke-CheckedCommand 'gh' @(
            'pr', 'list', '--repo', $fxciConfigRepo, '--state', 'all', '--head', $branch,
            '--json', 'number,url,state,headRefName'
        ) -GitHubToken $fxciConfigToken | ConvertFrom-Json
        $existingPr = @($existing | Where-Object { $_.headRefName -eq $branch }) | Select-Object -First 1
        if ($existingPr -and $existingPr.state -ne 'OPEN') {
            Write-Verbose "A deployment PR for this build date already exists ($($existingPr.state)): $($existingPr.url)"
            return $existingPr.url
        }

        $fxciRemote = "https://github.com/$fxciConfigRepo.git"
        $null = Invoke-CheckedCommand 'git' @(
            '-c', 'credential.helper=!gh auth git-credential', 'clone', '--branch', 'main', $fxciRemote, $fxciPath
        ) -GitHubToken $fxciConfigToken
        $null = Invoke-CheckedCommand 'git' @('-C', $fxciPath, 'remote', 'set-url', 'origin', $fxciRemote)
        $null = Invoke-CheckedCommand 'git' @('-C', $fxciPath, 'config', '--local', 'credential.helper', '!gh auth git-credential')
        $null = Invoke-CheckedCommand 'git' @('-C', $fxciPath, 'checkout', '--detach', 'origin/main')
        $workerImagesPath = Join-Path $fxciPath 'worker-images.yml'
        $content = [IO.File]::ReadAllText($workerImagesPath)
        $sourceContent = $content

        # Windows values live below their Azure provider key; update them separately.
        foreach ($update in ($updates | Where-Object { $_.platform -eq 'Windows' } | Sort-Object image)) {
            $content = Get-UpdatedWorkerImagesYaml -Content $content -ImageKey $update.image -Field 'version' -Value $update.version
            $content = Get-UpdatedWorkerImagesYaml -Content $content -ImageKey $update.image -Field 'deployment_id' -Value $update.deploymentId
        }
        foreach ($update in ($updates | Where-Object { $_.platform -eq 'Linux' } | Sort-Object image, provider)) {
            $content = Get-UpdatedWorkerImagesYaml -Content $content -ImageKey $update.image -Field $update.provider -Value $update.reference
        }

        [IO.File]::WriteAllText($workerImagesPath, $content, [Text.UTF8Encoding]::new($false))
        $diff = Invoke-CheckedCommand 'git' @('-C', $fxciPath, 'diff', '--', 'worker-images.yml')
        if ([string]::IsNullOrWhiteSpace($diff) -and -not $existingPr) {
            Write-Verbose 'fxci-config already references these images; no PR is needed.'
            return
        }
        if (-not [string]::IsNullOrWhiteSpace($diff)) { Write-Verbose $diff }

        $platforms = @()
        if ($AzureRunId) { $platforms += 'Windows' }
        if ($GcpRunId) { $platforms += 'Ubuntu' }
        $title = "chore(images): deploy production images - $deploymentDate"

        $windowsUpdates = @($updates | Where-Object { $_.platform -eq 'Windows' })
        $linuxUpdates = @($updates | Where-Object { $_.platform -eq 'Linux' })
        $puppetRangeMap = @{}
        foreach ($update in $windowsUpdates) {
            $base = Get-WorkerImageFieldValue -Content $sourceContent -ImageKey $update.image -Field 'deployment_id'
            if ($base -notmatch '^[a-fA-F0-9]{7,40}$') {
                throw "Cannot compare ronin_puppet history for '$($update.image)': invalid current deployment_id '$base'."
            }
            $rangeKey = "$base...$($update.deploymentIdFull)"
            if (-not $puppetRangeMap.ContainsKey($rangeKey)) {
                $puppetRangeMap[$rangeKey] = [pscustomobject]@{ base = $base; head = $update.deploymentIdFull }
            }
        }
        $puppetChanges = if ($puppetRangeMap.Count -gt 0) {
            Get-WindowsPuppetChangeMarkdown -Ranges @($puppetRangeMap.Values | Sort-Object base, head)
        } else { '' }

        $summary = "Update production $($platforms -join ' and ') worker images."

        $imageSections = [System.Collections.Generic.List[string]]::new()
        if ($windowsUpdates.Count -gt 0) {
            $imageSections.Add('### Windows')
            $imageSections.Add('')
            $imageSections.Add('| FXCI image | Azure version | ronin_puppet deployment | SBOM |')
            $imageSections.Add('|---|---:|---|---|')
            foreach ($update in ($windowsUpdates | Sort-Object image)) {
                $deploymentUrl = "https://github.com/$roninPuppetRepo/commit/$($update.deploymentIdFull)"
                $imageSections.Add("| ``$($update.image)`` | ``$($update.version)`` | [$($update.deploymentId)]($deploymentUrl) | [SBOM]($($update.sbomUrl)) |")
            }
            $imageSections.Add('')
        }
        if ($linuxUpdates.Count -gt 0) {
            $imageSections.Add('### Ubuntu')
            $imageSections.Add('')
            $imageSections.Add('| FXCI image | Level | GCP production image | SBOM |')
            $imageSections.Add('|---|---:|---|---|')
            foreach ($update in ($linuxUpdates | Sort-Object image, provider)) {
                $level = if ($update.provider -eq 'fxci-level1-gcp') { 'L1' } else { 'L3' }
                $imageSections.Add("| ``$($update.image)`` | $level | ``$($update.reference)`` | [SBOM]($($update.sbomUrl)) |")
            }
            $imageSections.Add('')
        }
        $imageSections.Add('Windows Server 2025 and alpha image references are not changed by this automation.')
        $imagesMarkdown = $imageSections -join "`n"

        $provenance = [System.Collections.Generic.List[string]]::new()
        $provenance.Add('| Platform | Production run | worker-images commit | Result |')
        $provenance.Add('|---|---|---|---|')
        if ($windowsRun) {
            $sourceSha = ([string]$windowsRun.headSha).Substring(0, 7)
            $sourceUrl = "https://github.com/$workerImagesRepo/commit/$($windowsRun.headSha)"
            $provenance.Add("| Windows | [run $AzureRunId]($($windowsRun.url)) | [$sourceSha]($sourceUrl) | $($windowsUpdates.Count) image builds succeeded |")
        }
        if ($gcpRun) {
            $sourceSha = ([string]$gcpRun.headSha).Substring(0, 7)
            $sourceUrl = "https://github.com/$workerImagesRepo/commit/$($gcpRun.headSha)"
            $provenance.Add("| GCP | [run $GcpRunId]($($gcpRun.url)) | [$sourceSha]($sourceUrl) | $($linuxUpdates.Count) image promotions succeeded |")
        }

        $body = @(
            '## Summary'
            ''
            $summary
            ''
            '## Images'
            ''
            $imagesMarkdown
            ''
            '## Build provenance'
            ''
            ($provenance -join "`n")
            ''
            $puppetChanges
        ) -join "`n"
        $bodyPath = Join-Path $tempRoot 'pull-request.md'
        [IO.File]::WriteAllText($bodyPath, $body, [Text.UTF8Encoding]::new($false))

        $remoteBranchRef = "refs/remotes/origin/$branch"
        $remoteBranch = Invoke-CheckedCommand 'git' @(
            '-C', $fxciPath, 'ls-remote', '--heads', 'origin', "refs/heads/$branch"
        ) -GitHubToken $fxciConfigToken
        $remoteBranchExists = -not [string]::IsNullOrWhiteSpace($remoteBranch)
        if ($remoteBranchExists) {
            $branchRefspec = "refs/heads/${branch}:$remoteBranchRef"
            $null = Invoke-CheckedCommand 'git' @('-C', $fxciPath, 'fetch', 'origin', $branchRefspec) -GitHubToken $fxciConfigToken
            $branchFiles = Invoke-CheckedCommand 'git' @(
                '-C', $fxciPath, 'diff', '--name-only', "origin/main...$remoteBranchRef"
            )
            $unexpectedFiles = @($branchFiles -split "\r?\n" | Where-Object { $_ -and $_ -ne 'worker-images.yml' })
            if ($unexpectedFiles.Count -gt 0) {
                throw "Deployment branch '$branch' contains unexpected files: $($unexpectedFiles -join ', ')."
            }
        }

        $target = if ($existingPr) { $existingPr.url } else { "$fxciConfigRepo/$branch" }
        $action = if ($existingPr) {
            'Update deployment branch and pull request'
        } elseif ($remoteBranchExists) {
            'Open deployment pull request from existing branch'
        } else {
            'Commit, push, and open deployment pull request'
        }
        if ($PSCmdlet.ShouldProcess($target, $action)) {
            if ($remoteBranchExists) {
                $null = Invoke-CheckedCommand 'git' @('-C', $fxciPath, 'restore', '--', 'worker-images.yml')
                $null = Invoke-CheckedCommand 'git' @('-C', $fxciPath, 'checkout', '-B', $branch, $remoteBranchRef)
                [IO.File]::WriteAllText($workerImagesPath, $content, [Text.UTF8Encoding]::new($false))
                $branchDiff = Invoke-CheckedCommand 'git' @('-C', $fxciPath, 'diff', '--', 'worker-images.yml')
                if (-not [string]::IsNullOrWhiteSpace($branchDiff)) {
                    $null = Invoke-CheckedCommand 'git' @('-C', $fxciPath, 'add', '--', 'worker-images.yml')
                    $null = Invoke-CheckedCommand 'git' @('-C', $fxciPath, '-c', 'user.name=worker-images image deployment', '-c', 'user.email=worker-images@users.noreply.github.com', 'commit', '-m', $title)
                    $null = Invoke-CheckedCommand 'git' @('-C', $fxciPath, 'push', '--set-upstream', 'origin', $branch) -GitHubToken $fxciConfigToken
                }
            } else {
                $null = Invoke-CheckedCommand 'git' @('-C', $fxciPath, 'checkout', '-b', $branch)
                $null = Invoke-CheckedCommand 'git' @('-C', $fxciPath, 'add', '--', 'worker-images.yml')
                $stagedFiles = Invoke-CheckedCommand 'git' @('-C', $fxciPath, 'diff', '--cached', '--name-only')
                if (-not [string]::IsNullOrWhiteSpace($stagedFiles)) {
                    $null = Invoke-CheckedCommand 'git' @('-C', $fxciPath, '-c', 'user.name=worker-images image deployment', '-c', 'user.email=worker-images@users.noreply.github.com', 'commit', '-m', $title)
                }
                $null = Invoke-CheckedCommand 'git' @('-C', $fxciPath, 'push', '--set-upstream', 'origin', $branch) -GitHubToken $fxciConfigToken
            }

            if ($existingPr) {
                $null = Invoke-CheckedCommand 'gh' @(
                    'pr', 'edit', [string]$existingPr.number, '--repo', $fxciConfigRepo,
                    '--title', $title, '--body-file', $bodyPath
                ) -GitHubToken $fxciConfigToken
                Write-Verbose "Updated deployment PR: $($existingPr.url)"
                return $existingPr.url
            }

            $url = Invoke-CheckedCommand 'gh' @(
                'pr', 'create', '--repo', $fxciConfigRepo, '--base', 'main', '--head', $branch,
                '--title', $title, '--body-file', $bodyPath
            ) -GitHubToken $fxciConfigToken
            Write-Verbose "Created deployment PR: $url"
            return $url
        }
    } finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -WhatIf:$false
        }
    }
}
