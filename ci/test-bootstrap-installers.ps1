# Offline checks of the production verifier and staging retry helpers; no installers run.
# Run from the repository root with Windows PowerShell 5.1 or PowerShell 7.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$mdc = Join-Path $repo 'provisioners/windows/MDC1Windows'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('bootstrap-installers-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $scratch | Out-Null
$state = @{ requests = 0; installs = 0; failures = 0; payload = 'verified'; exitCode = 0; urls = @() }
function Assert-Fails {
    param ([scriptblock] $Action, [string] $Message)
    try { & $Action } catch {
        if ($_.Exception.Message -notlike "*$Message*") { throw }
        return
    }
    throw "Expected failure containing: $Message"
}
function Start-Sleep { param ($Seconds) $state.sleeps++ }
function Write-Log { param ($message, $severity) }
function Invoke-WebRequest {
    param ($Uri, $OutFile, $TimeoutSec, $ErrorAction, $Headers, [switch] $UseBasicParsing)
    $state.requests++
    $state.urls += $Uri
    [IO.File]::WriteAllText($OutFile, $state.payload)
    if ($state.requests -le $state.failures) { throw 'Transient download failure' }
}
function Start-Process {
    param ($FilePath, $ArgumentList, [switch] $Wait, [switch] $PassThru, [switch] $NoNewWindow)
    $state.installs++
    $state.command = $FilePath
    $state.arguments = $ArgumentList
    if (-not ($Wait -and $PassThru)) { throw 'Installer was not awaited' }
    return [pscustomobject]@{ ExitCode = $state.exitCode }
}
try {
    Copy-Item (Join-Path $mdc 'bootstrap-installers.ps1') $scratch
    . (Join-Path $scratch 'bootstrap-installers.ps1')
    $source = Join-Path $scratch 'source'
    [IO.File]::WriteAllText($source, 'verified')
    $hash = (Get-FileHash $source -Algorithm SHA256).Hash
    $manifest = @{ files = @(
        @{ name = 'tool.exe'; sha256 = $hash; urls = @('https://mirror/tool.exe', 'https://upstream/tool.exe') },
        @{ name = 'tool.msi'; sha256 = $hash; urls = @('https://upstream/tool.msi') }
    ) }
    $manifestPath = Join-Path $scratch 'bootstrap-installers.json'
    $manifest | ConvertTo-Json -Depth 5 | Set-Content $manifestPath
    $destination = Join-Path $scratch 'installers with spaces'
    $params = @{ Name = 'tool.exe'; Destination = $destination; Arguments = '/quiet' }
    & { Set-StrictMode -Version Latest; Install-VerifiedBootstrapInstaller @params }
    $state.requests = 0; $state.installs = 0
    $state.failures = 1
    Install-VerifiedBootstrapInstaller @params
    if ($state.requests -ne 2 -or $state.installs -ne 1 -or $state.arguments -ne '/quiet') {
        throw 'Transient retry or EXE installation failed'
    }

    $state.requests = 0; $state.failures = 3
    Install-VerifiedBootstrapInstaller @params
    if ($state.requests -ne 4 -or $state.urls[-1] -ne 'https://upstream/tool.exe') {
        throw 'Mirror transport failure did not fall back to upstream'
    }

    $state.requests = 0; $state.failures = 0; $state.exitCode = 3010
    Install-VerifiedBootstrapInstaller -Name 'tool.msi' -Destination $destination -Arguments '/quiet /norestart ADDLOCAL=Server'
    if ($state.command -ne 'msiexec.exe' -or $state.arguments -ne "/i `"$(Join-Path $destination 'tool.msi')`" /quiet /norestart ADDLOCAL=Server") {
        throw 'MSI quoting or server-only arguments changed'
    }
    $state.exitCode = 1603
    Assert-Fails { Install-VerifiedBootstrapInstaller @params } 'exit code 1603'
    $state.exitCode = 0

    # A valid cache cannot mask a bad download, and a bad cache cannot bypass verification.
    $before = $state.installs
    $state.payload = 'tampered'; $state.requests = 0
    Assert-Fails { Install-VerifiedBootstrapInstaller @params } 'SHA-256 mismatch'
    if ($state.installs -ne $before -or $state.requests -ne 1 -or (Test-Path "$destination/tool.exe.partial")) {
        throw 'Tampered mirror executed, fell back, or leaked a partial file'
    }
    [IO.File]::WriteAllText((Join-Path $destination 'tool.exe'), 'tampered cache')
    $state.payload = 'verified'
    Install-VerifiedBootstrapInstaller @params
    if ((Get-Content (Join-Path $destination 'tool.exe') -Raw) -ne 'verified') { throw 'Unverified cache reused' }

    $before = $state.installs
    $state.failures = 99; $state.requests = 0
    Assert-Fails { Install-VerifiedBootstrapInstaller @params } 'All download attempts failed'
    if ($state.installs -ne $before -or $state.requests -ne 6 -or (Test-Path "$destination/tool.exe.partial")) {
        throw 'Retry exhaustion executed stale content or leaked a partial file'
    }
    Assert-Fails { Install-VerifiedBootstrapInstaller -Name '../tool.exe' -Destination $destination -Arguments '/quiet' } 'Unknown installer'
    Assert-Fails { Install-VerifiedBootstrapInstaller -Name 'unknown.exe' -Destination $destination -Arguments '/quiet' } 'Unknown installer'
    $manifest.files[0].sha256 = 'invalid'
    $manifest | ConvertTo-Json -Depth 5 | Set-Content $manifestPath
    Assert-Fails { Install-VerifiedBootstrapInstaller @params } 'invalid SHA-256'

    $manifest.files[0].sha256 = $hash
    $manifest.files[0].urls = @('http://insecure/tool.exe')
    $manifest | ConvertTo-Json -Depth 5 | Set-Content $manifestPath
    Assert-Fails { Install-VerifiedBootstrapInstaller @params } 'Invalid installer URLs'
    $manifest.files[0].urls = @('https://mirror/tool.exe')
    $manifest.files += $manifest.files[0]
    $manifest | ConvertTo-Json -Depth 5 | Set-Content $manifestPath
    Assert-Fails { Install-VerifiedBootstrapInstaller @params } 'Unknown installer'

    # Use actual function ASTs without executing any deployment script's top-level code.
    foreach ($scriptName in @('OS-deploy.ps1', 'Get-Bootstrap.ps1', 'bootstrap.ps1')) {
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $mdc $scriptName), [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count) { throw "Parse errors in $scriptName : $parseErrors" }
        if ($scriptName -eq 'OS-deploy.ps1') {
            $stager = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Update-GetBoot' }, $true)
            & {
                $revision = '0123456789012345678901234567890123456789'
                $staged = @{}
                function Join-Path { param($Path, $ChildPath) Microsoft.PowerShell.Management\Join-Path $scratch $ChildPath }
                function Invoke-DownloadWithRetry {
                    param($Url, $Path)
                    $name = Split-Path $Path -Leaf
                    if ($Url -ne "https://raw.githubusercontent.com/mozilla-platform-ops/worker-images/$revision/provisioners/windows/MDC1Windows/$name") {
                        throw 'Installer policy is not staged from the pinned worker-images revision'
                    }
                    if (Test-Path $Path) { throw 'Stale staged policy was reused' }
                    $staged[$name] = $true
                }
                # Execute the real staging loop against scratch paths, before template rendering.
                . ([scriptblock]::Create($stager.Body.EndBlock.Statements[0].Extent.Text))
                if ($staged.Count -ne 2 -or -not $staged['bootstrap-installers.ps1'] -or -not $staged['bootstrap-installers.json']) {
                    throw 'Installer helper/manifest were not staged together'
                }
            }
        }
        foreach ($functionName in @('Invoke-DownloadWithRetry', 'Invoke-DownloadWithRetryGithub')) {
            $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true)
            . ([scriptblock]::Create($definition.Extent.Text))
            $state.requests = 0; $state.sleeps = 0; $state.failures = 99
            # Unsupported scheme exercises WebClient failures without network access.
            Assert-Fails { & $functionName -Url 'invalid://offline/tool.exe' -Path (Join-Path $scratch 'retry.exe') -WarningAction SilentlyContinue } 'Package download failed after'
            if ($state.sleeps -ne 19) { throw "Incorrect retry bound in $scriptName" }
            $state.failures = 0
            $localUri = [uri]::new($source, [UriKind]::Absolute).AbsoluteUri
            $retryPath = Join-Path $scratch 'retry.exe'
            $result = & $functionName -Url $localUri -Path $retryPath
            if ($result -ne $retryPath -or (Get-Content $retryPath -Raw) -ne 'verified') {
                throw "Successful download did not return verified fixture bytes in $scriptName"
            }
        }
    }

    # Every current hardware Git version/architecture must have reviewed trust metadata.
    $realManifest = Get-Content (Join-Path $mdc 'bootstrap-installers.json') -Raw | ConvertFrom-Json
    $configs = @((Join-Path $mdc 'pools.yml'), (Join-Path $repo 'provisioners/windows/win-hw-wim/config/win-hw-wim-defaults.yaml'))
    foreach ($config in $configs) {
        foreach ($match in [regex]::Matches((Get-Content $config -Raw), 'git_version:\s*"([0-9.]+)"')) {
            foreach ($arch in @('64-bit', 'arm64')) {
                $name = "Git-$($match.Groups[1].Value)-$arch.exe"
                $entries = @($realManifest.files | Where-Object { $_.name -eq $name -and $_.sha256 -match '^[a-f0-9]{64}$' })
                if ($entries.Count -ne 1) { throw "Missing reviewed installer: $name" }
            }
        }
    }
    Write-Host 'Installer verification, tampering, cache, mirror fallback, exit codes, manifest coverage, and bootstrap retry exhaustion checks passed.'
} finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
