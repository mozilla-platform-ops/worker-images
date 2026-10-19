$ErrorActionPreference = 'Stop'
Import-Module powershell-yaml
$repo = Split-Path $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('image-source-test-' + [guid]::NewGuid())
$origin = Join-Path $testRoot 'origin'
$checkout = Join-Path $testRoot 'checkout'
$oldActor = $env:GITHUB_ACTOR
$oldTrigger = $env:GITHUB_TRIGGERING_ACTOR
$oldRevision = $env:WORKER_IMAGES_REVISION
$oldEnv = $env:GITHUB_ENV
$oldOutput = $env:GITHUB_OUTPUT
$oldWitness = $env:IMAGE_SOURCE_WITNESS
$azureKey = 'win11-64-24h2-alpha'
$gcpKey = 'gw-fxci-gcp-l1-2404-headless-alpha'

function Invoke-TestGit {
    param([string] $Directory, [string[]] $Arguments)
    $result = & git -C $Directory @Arguments 2>&1
    if ($LASTEXITCODE) { throw ($result -join "`n") }
    return $result
}
function Write-Yaml {
    param([string] $Root, [string] $Path, $Data)
    $file = Join-Path $Root $Path
    $null = New-Item -ItemType Directory -Path (Split-Path $file) -Force
    $Data | ConvertTo-Json -Depth 30 | Set-Content $file
}
function Reject {
    param([scriptblock] $Action, [string] $Message)
    try { & $Action } catch {
        if ($_.ToString() -notlike "*$Message*") { throw "Expected '$Message', got: $_" }
        return
    }
    throw "Expected rejection: $Message"
}
function Reload {
    Remove-Module WorkerImages -Force -ErrorAction SilentlyContinue
    Import-Module "$checkout/bin/WorkerImages/WorkerImages.psm1" -Force -DisableNameChecking
}
function global:Set-PSRepository { }
function global:Install-Module { }
function global:Start-Sleep { }
function global:packer {
    if ($env:WORKER_IMAGES_HELPER_MARKER -ne $global:ExpectedMarker) { throw 'Build used the original helper.' }
    if ((Get-Content 'scripts/marker' -Raw).Trim() -ne $global:ExpectedMarker) { throw 'Packer used the wrong checkout.' }
    if ($global:PackerFailure -eq $args[0]) {
        if ($global:FailOnce) { $global:PackerFailure = '' }
        $global:LASTEXITCODE = 7; return
    }
    if ($args[0] -eq 'build') {
        if ($global:ExpectedProvider -eq 'Azure') {
            if ($env:PKR_VAR_sharedimage_version -ne '9.8.7' -or $env:PKR_VAR_git_version -ne '9.9.9') {
                throw 'Azure did not re-read selected image YAML/defaults.'
            }
            $zip = Join-Path $env:PKR_VAR_upload_directory 'Bootstrap.zip'
            Expand-Archive $zip 'expanded-bootstrap' -Force
            if ((Get-Content 'expanded-bootstrap/Bootstrap/marker' -Raw).Trim() -ne $global:ExpectedMarker) { throw 'Azure uploaded original Bootstrap.' }
            Expand-Archive "$env:PKR_VAR_upload_directory/tests.zip" 'expanded-tests' -Force
            if ((Get-Content 'expanded-tests/marker' -Raw).Trim() -ne $global:ExpectedMarker) { throw 'Azure uploaded original tests.' }
            "selected notes" | Set-Content "$env:PKR_VAR_config-9.8.7.md"
        } else {
            if ($env:PKR_VAR_disk_size -ne '99') { throw 'GCP did not use selected config.' }
            if ((Get-Content 'tests/linux/marker' -Raw).Trim() -ne $global:ExpectedMarker) { throw 'GCP used original tests.' }
            $null = New-Item -ItemType Directory -Path sboms -Force
            'selected notes' | Set-Content "sboms/$env:PKR_VAR_image_name.md"
        }
    }
    $global:LASTEXITCODE = 0
}

try {
    $null = New-Item -ItemType Directory -Path $origin -Force
    $null = Invoke-TestGit $origin @('init', '-b', 'main')
    $null = Invoke-TestGit $origin @('config', 'user.name', 'Image Source Test')
    $null = Invoke-TestGit $origin @('config', 'user.email', 'image-source@example.invalid')
    Copy-Item "$repo/bin" $origin -Recurse
    Copy-Item "$repo/ci" $origin -Recurse
    Copy-Item "$repo/config" $origin -Recurse
    Copy-Item "$repo/azure.pkr.hcl", "$repo/gcp.pkr.hcl" $origin
    foreach ($dir in @('scripts/windows/CustomFunctions/Bootstrap', 'scripts/linux', 'tests/win', 'tests/linux')) {
        $null = New-Item -ItemType Directory "$origin/$dir" -Force
        'main' | Set-Content "$origin/$dir/marker"
    }
    'main' | Set-Content "$origin/scripts/marker"
    $null = New-Item -ItemType Directory "$origin/.github" -Force
    '["relops-test"]' | Set-Content "$origin/.github/relsre.json"
    $null = Invoke-TestGit $origin @('add', '.')
    $null = Invoke-TestGit $origin @('commit', '-m', 'base')
    $null = Invoke-TestGit $testRoot @('clone', $origin, $checkout)
    Push-Location $checkout
    $env:GITHUB_ACTOR = 'relops-test'
    $env:GITHUB_TRIGGERING_ACTOR = ''
    $env:WORKER_IMAGES_REVISION = ''
    $env:GITHUB_ENV = ''
    $env:GITHUB_OUTPUT = ''
    Reload
    $env:GITHUB_ACTOR = ''
    $env:GITHUB_OUTPUT = "$checkout/metadata.outputs"
    Set-AzWorkerImageLocation -Key generic-worker-win2022-staging -Team tceng
    $values = Get-Content $env:GITHUB_OUTPUT -Raw | ConvertFrom-StringData
    if ($values.CLIENT_ID_SECRET -ne 'AZURE_CLIENT_ID_FXCI' -or
        ($values.LOCATIONS | ConvertFrom-Json) -join ',' -ne 'centralus,eastus') {
        throw 'Trusted Azure metadata changed for a config without dev.'
    }
    Clear-Content $env:GITHUB_OUTPUT
    Set-GCPWorkerImageProject -Key generic-worker-ubuntu-24-04-staging -Team tceng
    Set-GCPWorkerImageName -Key $gcpKey
    $values = Get-Content $env:GITHUB_OUTPUT -Raw | ConvertFrom-StringData
    if ($values.PROJECT -ne 'taskcluster-imaging' -or $values.IMAGENAME -ne 'gw-fxci-gcp-l1-2404-amd64-headless-googlecompute-alpha') {
        throw 'Trusted GCP metadata changed for configs without dev.'
    }
    $env:GITHUB_OUTPUT = ''
    if ((Set-GCPWorkerImageProject -Key $gcpKey -Team custom) -ne 'PROJECT=taskcluster-imaging') { throw 'Absent dev changed custom team config lookup.' }
    $plain = Get-WorkerImageSource -Key $azureKey -Provider Azure
    if ($plain.Root -ne $checkout -or $plain.Revision) { throw 'Absent dev changed checkout behavior.' }

    foreach ($actor in @('', 'tceng-only', 'foofrix-only', 'relops-test')) {
        $env:GITHUB_ACTOR = $actor
        foreach ($dev in @($null, '', 1, $false, @('branch'), @{ branch = 'branch' }, 'dev/test')) {
            foreach ($team in @('tceng', 'foofrix', 'other')) {
                Write-Yaml $checkout "config/$team/fake-alpha.yaml" @{ dev = $dev }
                Reject { Get-WorkerImageSource -Key fake-alpha -Team $team -Provider Azure } 'dev is not permitted in config subdirectories'
            }
            Write-Yaml $checkout 'config/unknown/deep/fake-alpha.yaml' @{ dev = $dev }
            Reject {
                & (Get-Module WorkerImages) {
                    param($root)
                    Read-WorkerImageYaml -Root $root -Path 'config/unknown/deep/fake-alpha.yaml'
                } $checkout
            } 'dev is not permitted in config subdirectories'
            Write-Yaml $checkout 'config/fake.yaml' @{ dev = $dev }
            $message = if ($actor -eq 'relops-test') { 'only for alpha images' } else { 'restricted to the RelOps team' }
            Reject { Get-WorkerImageSource -Key fake -Provider GCP } $message
        }
    }
    $env:GITHUB_ACTOR = 'relops-test'
    foreach ($entry in @(
        @('trusted-gw-fxci-gcp-l3-2404-headless-alpha', 'GCP'),
        @('trusted-gw-fxci-gcp-l3-2404-arm64-headless-alpha', 'GCP'),
        @('win11-64-24h2-trusted-alpha', 'Azure')
    )) {
        $key = $entry[0]
        $sourceKey = if ($entry[1] -eq 'Azure') { $azureKey } else { $key }
        $data = ConvertFrom-Yaml (Get-Content "$repo/config/$sourceKey.yaml" -Raw)
        Write-Yaml $checkout "config/$key.yaml" $data
        if ((Get-WorkerImageSource -Key $key -Provider $entry[1]).Root -ne $checkout) { throw 'Trusted build without dev changed.' }
        foreach ($dev in @($null, '', 1, $false, @('branch'), @{ branch = 'branch' }, 'missing/branch')) {
            $data.dev = $dev
            Write-Yaml $checkout "config/$key.yaml" $data
            Reject { Get-WorkerImageSource -Key $key -Provider $entry[1] } 'Not authorized: dev branch selection is not permitted for trusted images'
        }
    }
    Write-Yaml $checkout 'config/renamed-alpha.yaml' @{
        dev = 'missing/branch'
        image = @{ image_name = 'renamed-alpha'; project_id = 'fxci-production-level3-workers' }
    }
    Reject { Get-WorkerImageSource -Key renamed-alpha -Provider GCP } 'Not authorized: dev cannot target the trusted L3 GCP project'
    foreach ($action in @(
        { New-GCPWorkerImage -Key fake-alpha -Team tceng },
        { Set-GCPWorkerImageName -Key fake-alpha -Team tceng },
        { Set-GCPWorkerImageProject -Key fake-alpha -Team tceng },
        { Set-AzWorkerImageLocation -Key fake-alpha -Team tceng },
        { New-AzWorkerImage -Key fake-alpha -Team tceng -Location test -Client_ID test -Subscription_ID test -Tenant_ID test -Application_ID test -oidc_request_url test -oidc_request_token test }
    )) {
        Reject $action 'dev is not permitted in config subdirectories'
    }
    foreach ($dev in @($null, '', ' ', 1, $false, @('branch'), @{ branch = 'branch' })) {
        Write-Yaml $checkout 'config/fake-alpha.yaml' @{ dev = $dev }
        Reject { Get-WorkerImageSource -Key fake-alpha -Provider GCP } 'nonempty'
    }
    Reject { Get-WorkerImageSource -Key '../fake-alpha' -Provider Azure } 'without paths'
    $yaml = ConvertFrom-Yaml (Get-Content "$repo/config/$azureKey.yaml" -Raw)
    $yaml.dev = 'missing/branch'
    Write-Yaml $checkout "config/$azureKey.yaml" $yaml
    Reject { Get-WorkerImageSource -Key $azureKey -Provider Azure } 'git ls-remote failed'
    $yaml.dev = 'bad branch'
    Write-Yaml $checkout "config/$azureKey.yaml" $yaml
    Reject { Get-WorkerImageSource -Key $azureKey -Provider Azure } 'git check-ref-format failed'

    $yaml.dev = 'missing/branch'
    $yaml.sharedimage.image_name = 'production'
    Write-Yaml $checkout "config/$azureKey.yaml" $yaml
    Reject { Get-WorkerImageSource -Key $azureKey -Provider Azure } 'non-alpha Azure'
    Write-Yaml $checkout 'config/fake-alpha.yaml' @{ dev = 'missing/branch'; image = @{ image_name = 'production' } }
    Reject { Get-WorkerImageSource -Key fake-alpha -Provider GCP } 'non-alpha GCP'
    New-Item -ItemType SymbolicLink -Path 'config/link-alpha.yaml' -Target 'tceng/fake-alpha.yaml' | Out-Null
    Reject { Get-WorkerImageSource -Key link-alpha -Provider Azure } 'contains a link'
    Move-Item '.github/relsre.json' '.github/relsre.saved'
    Reject { Get-WorkerImageSource -Key fake-alpha -Provider GCP } 'trusted RelOps allowlist is unavailable'
    Move-Item '.github/relsre.saved' '.github/relsre.json'

    $env:IMAGE_SOURCE_WITNESS = "$checkout/branch-code-executed"
    # Different images select independent branches, with dev retained in branch YAML.
    foreach ($entry in @(@($azureKey, 'Azure', 'dev/azure'), @($gcpKey, 'GCP', 'dev/gcp'))) {
        $key, $provider, $branch = $entry
        $null = Invoke-TestGit $origin @('checkout', '-B', $branch, 'main')
        $data = ConvertFrom-Yaml (Get-Content "$origin/config/$key.yaml" -Raw)
        $data.dev = $branch
        if ($provider -eq 'Azure') {
            $data.sharedimage.image_version = '9.8.7'
            $defaults = ConvertFrom-Yaml (Get-Content "$origin/config/windows_production_defaults.yaml" -Raw)
            $defaults.vm.git_version = '9.9.9'
            $data.vm.git_version = 'default'
            Write-Yaml $origin 'config/windows_production_defaults.yaml' $defaults
        } else {
            $data.vm.disk_size = 99
            $data.image.image_name = $data.image.image_name -replace '-alpha$', '-branch-alpha'
        }
        $modulePath = "$origin/bin/WorkerImages/WorkerImages.psm1"
        $moduleCode = Get-Content $modulePath -Raw
        ('Set-Content -LiteralPath $env:IMAGE_SOURCE_WITNESS -Value loaded' + "`n" + $moduleCode) | Set-Content $modulePath
        $helper = if ($provider -eq 'Azure') { 'New-AzSharedWorkerImage' } else { 'New-GCPWorkerImage' }
        $helperPath = "$origin/bin/WorkerImages/Public/$helper.ps1"
        $helperCode = Get-Content $helperPath -Raw
        $helperCode.Replace('    Install-Module powershell-yaml -ErrorAction Stop', "    Install-Module powershell-yaml -ErrorAction Stop`n    `$env:WORKER_IMAGES_HELPER_MARKER = '$branch'") | Set-Content $helperPath

        Write-Yaml $origin "config/$key.yaml" $data
        foreach ($file in @('scripts/marker', 'scripts/windows/CustomFunctions/Bootstrap/marker', 'scripts/linux/marker', 'tests/win/marker', 'tests/linux/marker')) {
            $branch | Set-Content "$origin/$file"
        }
        # This must not replace the trusted RelOps allowlist.
        '["attacker"]' | Set-Content "$origin/.github/relsre.json"
        $null = Invoke-TestGit $origin @('add', '.')
        $null = Invoke-TestGit $origin @('commit', '-m', $branch)
        $base = ConvertFrom-Yaml (Get-Content "$repo/config/$key.yaml" -Raw)
        $base.dev = $branch
        Write-Yaml $checkout "config/$key.yaml" $base
    }
    # Exercise the workflow selector in a fresh process, including its metadata outputs.
    $env:GITHUB_ENV = "$checkout/action.env"
    $env:GITHUB_OUTPUT = "$checkout/action.outputs"
    $beforeSelection = (& git worktree list --porcelain) -join "`n"
    & (Get-Process -Id $PID).Path -NoProfile -File "$checkout/ci/select-image-source.ps1" -Key $gcpKey -Provider GCP
    if ($LASTEXITCODE) { throw 'Workflow source selector failed.' }
    if ($beforeSelection -ne ((& git worktree list --porcelain) -join "`n")) { throw 'Selector left an unused worktree.' }
    $metadata = Get-Content $env:GITHUB_OUTPUT -Raw | ConvertFrom-StringData
    if ($metadata.IMAGENAME -notmatch '-branch-alpha$' -or $metadata.revision -notmatch '^[0-9a-f]{40}$') {
        throw 'Workflow metadata came from the original config.'
    }
    if ((Get-Content $env:GITHUB_ENV -Raw).Trim() -ne "WORKER_IMAGES_REVISION=$($metadata.revision)") {
        throw 'Workflow did not persist the selected commit.'
    }
    $env:GITHUB_ENV = ''; $env:GITHUB_OUTPUT = ''
    'unrelated concurrent fetch' | Set-Content '.git/FETCH_HEAD'
    Reload
    $beforeRejection = @(& git worktree list --porcelain)
    foreach ($entry in @(@($azureKey, 'Azure'), @($gcpKey, 'GCP'))) {
        Reject { Get-WorkerImageSource -Key $entry[0] -Provider $entry[1] -RejectDev } 'dev branch selection is not supported'
    }
    if (($beforeRejection -join "`n") -ne ((& git worktree list --porcelain) -join "`n")) {
        throw 'Unsupported workflow created a dev worktree.'
    }
    foreach ($action in @(
        { Set-AzWorkerImageLocation -Key $azureKey },
        { Set-GCPWorkerImageName -Key $gcpKey },
        { Set-GCPWorkerImageProject -Key $gcpKey }
    )) {
        Reject $action 'dev branch selection is not supported'
    }
    $az = Get-WorkerImageSource -Key $azureKey -Provider Azure
    $gcp = Get-WorkerImageSource -Key $gcpKey -Provider GCP
    if ((Get-Content '.git/FETCH_HEAD' -Raw).Trim() -ne 'unrelated concurrent fetch') { throw 'Image selection modified shared FETCH_HEAD.' }
    if ($az.Root -eq $gcp.Root -or $az.Revision -eq $gcp.Revision) { throw 'Image sources were not isolated.' }
    if ((Get-Content scripts/marker -Raw).Trim() -ne 'main') { throw 'Original checkout was changed.' }
    if (Test-Path $env:IMAGE_SOURCE_WITNESS) { throw 'Source selection or metadata lookup executed branch code.' }
    $global:PackerFailure = ''
    $global:ExpectedMarker = 'dev/azure'; $global:ExpectedProvider = 'Azure'
    New-AzSharedWorkerImage -Key $azureKey 6>$null
    if ((Get-WorkerImageSource -Key $gcpKey -Provider GCP).Root -ne $gcp.Root) { throw 'Branch handoff reset the original source cache.' }
    if (-not (Test-Path "$azureKey-9.8.7.md")) { throw 'Azure artifact was not returned.' }
    $azureNotes = Get-Content "$azureKey-9.8.7.md" -Raw
    if ($azureNotes -notlike "*DEV BUILD*dev/azure*$($az.Revision)*selected notes*") { throw 'Azure notes lack dev provenance.' }
    # Run the actual workflow loop with one transient failure, then with persistent failure.
    $workflow = Get-Content "$repo/.github/workflows/sig-nontrusted.yml" -Raw
    $loop = [regex]::Match($workflow, '(?s)          \$maxAttempts = 10.*?(?=          "sharedimageversion=)').Value
    if (-not $loop) { throw 'Azure workflow retry loop not found.' }
    $retry = [scriptblock]::Create($loop.Replace('exit 1', "throw 'Retry limit reached'"))
    $Vars = @{ Key = $azureKey }
    $global:FailOnce = $true; $global:PackerFailure = 'build'
    . $retry 6>$null
    if ($attempt -ne 2) { throw 'Azure dev build did not retry after a thrown Packer failure.' }
    if ((Get-WorkerImageSource -Key $azureKey -Provider Azure).Revision -ne $az.Revision) { throw 'Retry changed the pinned source.' }
    $global:FailOnce = $false; $global:PackerFailure = 'build'
    Reject { . $retry 6>$null } 'Retry limit reached'
    $global:PackerFailure = ''
    $global:ExpectedMarker = 'dev/gcp'; $global:ExpectedProvider = 'GCP'
    New-GCPWorkerImage -Key $gcpKey 6>$null
    if (-not (Test-Path "sboms/$($gcp.Yaml.image.image_name).md")) { throw 'GCP artifact was not returned.' }
    $gcpNotes = Get-Content "sboms/$($gcp.Yaml.image.image_name).md" -Raw
    if ($gcpNotes -notlike "*DEV BUILD*dev/gcp*$($gcp.Revision)*selected notes*") { throw 'GCP notes lack dev provenance.' }
    if ((Get-Location).Path -ne $checkout) { throw 'Build did not restore working directory.' }
    foreach ($stage in @('init', 'build')) {
        $global:PackerFailure = $stage
        Reject { New-GCPWorkerImage -Key $gcpKey 6>$null } "packer $stage failed with exit code 7"
        if ((Get-Location).Path -ne $checkout) { throw 'Packer failure did not restore the working directory.' }
    }
    $global:PackerFailure = ''
    $env:GITHUB_ACTOR = 'attacker'
    Reject { Get-WorkerImageSource -Key $azureKey -Provider Azure } 'restricted to the RelOps team'
    $env:GITHUB_ACTOR = 'relops-test'; $env:GITHUB_TRIGGERING_ACTOR = 'attacker'
    Reject { Get-WorkerImageSource -Key $azureKey -Provider Azure } 'restricted to the RelOps team'
    $env:GITHUB_TRIGGERING_ACTOR = ''

    # A branch moving between jobs cannot change a pinned build.
    $null = Invoke-TestGit $origin @('checkout', 'dev/gcp')
    'moved' | Set-Content "$origin/scripts/marker"
    $null = Invoke-TestGit $origin @('add', '.')
    $null = Invoke-TestGit $origin @('commit', '-m', 'move branch')
    Reload
    $pinned = Get-WorkerImageSource -Key $gcpKey -Provider GCP -Revision $gcp.Revision
    if ($pinned.Revision -ne $gcp.Revision -or (Get-Content "$($pinned.Root)/scripts/marker" -Raw).Trim() -ne 'dev/gcp') {
        throw 'Build did not retain the pinned revision.'
    }
    # Selected config cannot redirect an alpha build to production or another identity.
    foreach ($mutation in @('image', 'path', 'project', 'l3', 'missing')) {
        $null = Invoke-TestGit $origin @('checkout', '-B', "bad/$mutation", 'dev/gcp')
        $data = ConvertFrom-Yaml (Get-Content "$origin/config/$gcpKey.yaml" -Raw)
        if ($mutation -eq 'image') { $data.image.image_name = 'production' }
        if ($mutation -eq 'path') { $data.image.image_name = '../outside-alpha' }
        if ($mutation -eq 'project') { $data.image.project_id = 'other-project' }
        if ($mutation -eq 'l3') { $data.image.project_id = 'fxci-production-level3-workers' }
        Write-Yaml $origin "config/$gcpKey.yaml" $data
        if ($mutation -eq 'missing') { Remove-Item "$origin/gcp.pkr.hcl" }
        $null = Invoke-TestGit $origin @('add', '.')
        $null = Invoke-TestGit $origin @('commit', '-m', "bad $mutation")
        $base = ConvertFrom-Yaml (Get-Content "$checkout/config/$gcpKey.yaml" -Raw)
        $base.dev = "bad/$mutation"
        Write-Yaml $checkout "config/$gcpKey.yaml" $base
        Reload
        $message = switch ($mutation) { image { 'non-alpha GCP image' } path { 'non-alpha GCP image' } project { 'cannot change the GCP project' } l3 { 'Not authorized: dev cannot target the trusted L3 GCP project' } missing { 'Missing dev build input' } }
        if ($mutation -eq 'missing') {
            & (Get-Module WorkerImages) {
                $script:OriginalTestGit = ${function:Invoke-WorkerImageGit}
                function script:Invoke-WorkerImageGit {
                    param([string] $Root, [string[]] $Arguments)
                    if ($Arguments[0] -eq 'worktree' -and $Arguments[1] -eq 'remove') { throw 'Simulated cleanup failure' }
                    & $script:OriginalTestGit $Root $Arguments
                }
            }
        }
        Reject { Get-WorkerImageSource -Key $gcpKey -Provider GCP } $message
    }
    foreach ($mutation in @('gallery', 'pool', 'defaults', 'link')) {
        $null = Invoke-TestGit $origin @('checkout', '-B', "bad/azure-$mutation", 'dev/azure')
        $data = ConvertFrom-Yaml (Get-Content "$origin/config/$azureKey.yaml" -Raw)
        if ($mutation -eq 'gallery') { $data.sharedimage.gallery_name = 'production' }
        if ($mutation -eq 'pool') { $data.vm.tags.worker_pool_id = 'production' }
        if ($mutation -eq 'defaults') {
            $defaults = ConvertFrom-Yaml (Get-Content "$origin/config/windows_production_defaults.yaml" -Raw)
            $defaults.dev = 'other-branch'
            Write-Yaml $origin 'config/windows_production_defaults.yaml' $defaults
        }
        if ($mutation -eq 'link') {
            New-Item -ItemType SymbolicLink -Path "$origin/scripts/escape" -Target '/tmp' | Out-Null
        }
        Write-Yaml $origin "config/$azureKey.yaml" $data
        $null = Invoke-TestGit $origin @('add', '.')
        $null = Invoke-TestGit $origin @('commit', '-m', "bad Azure $mutation")
        $base = ConvertFrom-Yaml (Get-Content "$repo/config/$azureKey.yaml" -Raw)
        $base.dev = "bad/azure-$mutation"
        Write-Yaml $checkout "config/$azureKey.yaml" $base
        Reload
        $message = switch ($mutation) { defaults { 'not defaults' } link { 'must not contain symbolic links' } default { 'non-alpha Azure' } }
        Reject { Get-WorkerImageSource -Key $azureKey -Provider Azure } $message
    }
    Write-Host 'Image source authorization, validation, immutable selection, isolation, Azure uploads, and GCP provisioning checks passed.'
} finally {
    if ((Get-Location).Path -eq $checkout) { Pop-Location }
    $env:GITHUB_ACTOR = $oldActor
    $env:GITHUB_TRIGGERING_ACTOR = $oldTrigger
    $env:WORKER_IMAGES_REVISION = $oldRevision
    $env:GITHUB_ENV = $oldEnv
    $env:GITHUB_OUTPUT = $oldOutput
    $env:IMAGE_SOURCE_WITNESS = $oldWitness
    Remove-Module WorkerImages -Force -ErrorAction SilentlyContinue
    if (Test-Path "$checkout/.git") {
        foreach ($line in (& git -C $checkout worktree list --porcelain)) {
            if ($line -like 'worktree *') {
                $directory = $line.Substring(9)
                if ($directory -ne $checkout) { & git -C $checkout worktree remove --force $directory }
            }
        }
    }
    if (Test-Path $testRoot) { Remove-Item $testRoot -Recurse -Force }
    foreach ($name in @('Set-PSRepository', 'Install-Module', 'Start-Sleep', 'packer')) { Remove-Item "Function:global:$name" -ErrorAction SilentlyContinue }
}
