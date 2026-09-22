$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$path = Join-Path $PSScriptRoot '../scripts/windows/CustomFunctions/Bootstrap/Public/Install-AzPreReq.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors) { throw $errors }
$assignment = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$git_release'
}, $true)
if (-not $assignment) { throw 'Git release assignment is missing.' }
$resolve = [scriptblock]::Create($assignment.Extent.Text)
foreach ($case in @(
    @{ version = '2.54.0'; release = '2.54.0.windows.1' },
    @{ version = '2.55.0'; release = '2.55.0.windows.1' },
    @{ version = '2.55.0.5'; release = '2.55.0.windows.5' }
)) {
    $git_version = $case.version
    . $resolve
    if ($git_release -ne $case.release) {
        throw "Wrong Git release for ${git_version}: $git_release"
    }
}
Write-Host 'Git release checks passed.'
