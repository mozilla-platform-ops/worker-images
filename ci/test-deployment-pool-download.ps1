# Exercise the actual pool download/read statements with different process and PowerShell directories.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'provisioners/windows/MDC1Windows/OS-deploy.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$function = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DownloadWithRetryGithub' }, $true)
Invoke-Expression $function.Extent.Text.Replace('function Invoke-DownloadWithRetryGithub', 'function Invoke-TestDownload')
$download = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-DownloadWithRetryGithub' -and $node.Extent.Text.Contains('/pools.yml') }, $true)
$read = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$YAML' }, $true)
$pathAssignment = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$poolsPath' }, $true)
$copy = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Copy-Item' -and $node.Extent.Text.Contains('$local_yaml') }, $true)
function Invoke-DownloadWithRetryGithub {
    param($Url, $Path, $PAT)
    if ($Url -notlike "*/$workerImagesRevision/provisioners/windows/MDC1Windows/pools.yml") { throw 'Pool download must use the pinned revision.' }
    Invoke-TestDownload -Url $script:sourceUri -Path $Path -PAT $PAT
}
function ConvertFrom-Yaml {
    param($Content)
    if ($Content.Trim() -ne 'feature-branch-pools') { throw 'Read stale pools.yml instead of the downloaded branch configuration.' }
    return $Content
}
$temp = Join-Path $root ('.pool-download-test-' + [guid]::NewGuid())
$oldLocation = Get-Location
$oldProcessDirectory = [Environment]::CurrentDirectory
try {
    foreach ($directory in 'process', 'working', 'source') { New-Item -ItemType Directory -Path (Join-Path $temp $directory) -Force | Out-Null }
    $sourceFile = Join-Path $temp 'source\pools.yml'
    Set-Content -LiteralPath $sourceFile -Value 'feature-branch-pools'
    $script:sourceUri = ([uri]$sourceFile).AbsoluteUri
    Set-Content -LiteralPath (Join-Path $temp 'working\pools.yml') -Value 'stale-main-pools'
    [Environment]::CurrentDirectory = Join-Path $temp 'process'
    Set-Location (Join-Path $temp 'working')
    $workerImagesRevision = 'a' * 40
    $workerImagesPAT = 'test-only'
    if ($pathAssignment) { Invoke-Expression $pathAssignment.Extent.Text }
    Invoke-Expression $download.Extent.Text
    Invoke-Expression $read.Extent.Text
    $local_yaml = Join-Path $temp 'copied-pools.yaml'
    Invoke-Expression $copy.Extent.Text
    if ((Get-Content -LiteralPath $local_yaml -Raw).Trim() -ne 'feature-branch-pools') { throw 'Staged the wrong pool configuration.' }
    Write-Host 'Pool download/read/copy checks passed.'
}
finally {
    Set-Location $oldLocation
    [Environment]::CurrentDirectory = $oldProcessDirectory
    Remove-Item -LiteralPath $temp -Recurse -Force
}
