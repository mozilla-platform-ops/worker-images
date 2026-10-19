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
function global:packer {
    if ((Get-Content 'scripts/marker' -Raw).Trim() -ne $global:ExpectedMarker) { throw 'Packer used the wrong checkout.' }
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
    $plain = Get-WorkerImageSource -Key $azureKey -Provider Azure
    if ($plain.Root -ne $checkout -or $plain.Revision) { throw 'Absent dev changed checkout behavior.' }

    foreach ($actor in @('', 'tceng-only', 'foofrix-only', 'relops-test')) {
        $env:GITHUB_ACTOR = $actor
        foreach ($dev in @($null, '', 1, $false, @('branch'), @{ branch = 'branch' }, 'dev/test')) {
            foreach ($team in @('tceng', 'foofrix', 'other')) {
                Write-Yaml $checkout "config/$team/fake-alpha.yaml" @{ dev = $dev }
                Reject { Get-WorkerImageSource -Key fake-alpha -Team $team -Provider Azure } 'dev is not permitted in config subdirectories'
            }
            Write-Yaml $checkout 'config/fake.yaml' @{ dev = $dev }
            $message = if ($actor -eq 'relops-test') { 'only for alpha images' } else { 'restricted to the RelOps team' }
            Reject { Get-WorkerImageSource -Key fake -Provider GCP } $message
        }
    }
    $env:GITHUB_ACTOR = 'relops-test'
    foreach ($dev in @($null, '', ' ', 1, $false, @('branch'), @{ branch = 'branch' })) {
        Write-Yaml $checkout 'config/fake-alpha.yaml' @{ dev = $dev }
        Reject { Get-WorkerImageSource -Key fake-alpha -Provider GCP } 'nonempty'
    }
    Reject { Get-WorkerImageSource -Key '../fake-alpha' -Provider Azure } 'without paths'
    $yaml = ConvertFrom-Yaml (Get-Content "$repo/config/$azureKey.yaml" -Raw)
    $yaml.dev = 'missing/branch'
    Write-Yaml $checkout "config/$azureKey.yaml" $yaml
    Reject { Get-WorkerImageSource -Key $azureKey -Provider Azure } 'git fetch failed'
    $yaml.dev = 'bad branch'
    Write-Yaml $checkout "config/$azureKey.yaml" $yaml
    Reject { Get-WorkerImageSource -Key $azureKey -Provider Azure } 'git check-ref-format failed'

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
        } else { $data.vm.disk_size = 99 }
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
    Reload
    $az = Get-WorkerImageSource -Key $azureKey -Provider Azure
    $gcp = Get-WorkerImageSource -Key $gcpKey -Provider GCP
    if ($az.Root -eq $gcp.Root -or $az.Revision -eq $gcp.Revision) { throw 'Image sources were not isolated.' }
    if ((Get-Content scripts/marker -Raw).Trim() -ne 'main') { throw 'Original checkout was changed.' }
    $global:ExpectedMarker = 'dev/azure'; $global:ExpectedProvider = 'Azure'
    New-AzSharedWorkerImage -Key $azureKey 6>$null
    if ((Get-WorkerImageSource -Key $gcpKey -Provider GCP).Root -ne $gcp.Root) { throw 'Branch handoff reset the original source cache.' }
    if (-not (Test-Path "$azureKey-9.8.7.md")) { throw 'Azure artifact was not returned.' }
    $global:ExpectedMarker = 'dev/gcp'; $global:ExpectedProvider = 'GCP'
    New-GCPWorkerImage -Key $gcpKey 6>$null
    if (-not (Test-Path "sboms/$($gcp.Yaml.image.image_name).md")) { throw 'GCP artifact was not returned.' }
    if ((Get-Location).Path -ne $checkout) { throw 'Build did not restore working directory.' }
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
    foreach ($mutation in @('image', 'project', 'missing')) {
        $null = Invoke-TestGit $origin @('checkout', '-B', "bad/$mutation", 'dev/gcp')
        $data = ConvertFrom-Yaml (Get-Content "$origin/config/$gcpKey.yaml" -Raw)
        if ($mutation -eq 'image') { $data.image.image_name = 'production' }
        if ($mutation -eq 'project') { $data.image.project_id = 'other-project' }
        Write-Yaml $origin "config/$gcpKey.yaml" $data
        if ($mutation -eq 'missing') { Remove-Item "$origin/gcp.pkr.hcl" }
        $null = Invoke-TestGit $origin @('add', '.')
        $null = Invoke-TestGit $origin @('commit', '-m', "bad $mutation")
        $base = ConvertFrom-Yaml (Get-Content "$checkout/config/$gcpKey.yaml" -Raw)
        $base.dev = "bad/$mutation"
        Write-Yaml $checkout "config/$gcpKey.yaml" $base
        Reload
        $message = switch ($mutation) { image { 'non-alpha GCP image' } project { 'cannot change the GCP project' } missing { 'Missing dev build input' } }
        Reject { Get-WorkerImageSource -Key $gcpKey -Provider GCP } $message
    }
    Write-Host 'Image source authorization, validation, immutable selection, isolation, Azure uploads, and GCP provisioning checks passed.'
} finally {
    if ((Get-Location).Path -eq $checkout) { Pop-Location }
    $env:GITHUB_ACTOR = $oldActor
    $env:GITHUB_TRIGGERING_ACTOR = $oldTrigger
    $env:WORKER_IMAGES_REVISION = $oldRevision
    $env:GITHUB_ENV = $oldEnv
    $env:GITHUB_OUTPUT = $oldOutput
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
    foreach ($name in @('Set-PSRepository', 'Install-Module', 'packer')) { Remove-Item "Function:global:$name" -ErrorAction SilentlyContinue }
}
