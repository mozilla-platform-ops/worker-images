# Exercise the actual cleanup guard against a disposable HKCU key, never HKLM.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scriptPath = Join-Path $PSScriptRoot '../provisioners/windows/win-hw-wim/scripts/sysprep-generalize.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Sysprep script has syntax errors.' }
$guard = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
    $node.Extent.Text.StartsWith('foreach ($path in $buildPolicies.Keys)')
}, $true)
if (-not $guard) { throw 'Build policy guard not found.' }
$check = [scriptblock]::Create($guard.Extent.Text)
$testPath = 'HKCU:\Software\WimPolicyTest-' + [guid]::NewGuid()
$buildPolicies = @{ $testPath = @('AllowBasic', 'AllowUnencryptedTraffic', 'LocalAccountTokenFilterPolicy') }
try {
    & $check # Absent key is clean.
    New-Item -Path $testPath -Force | Out-Null
    & $check # Existing key with absent values is clean.
    foreach ($policy in $buildPolicies[$testPath]) {
        foreach ($value in @(0, 1)) {
            New-ItemProperty -Path $testPath -Name $policy -Value $value -PropertyType DWord -Force | Out-Null
            $rejected = $false
            try { & $check } catch {
                if ($_.Exception.Message -ne "Build-only policy $policy remains before capture.") { throw }
                $rejected = $true
            }
            if (-not $rejected) { throw "$policy=$value must prevent capture." }
        }
        Remove-ItemProperty -Path $testPath -Name $policy
        & $check
    }
    'WIM policy checks passed'
}
finally {
    Remove-Item -LiteralPath $testPath -Recurse -Force -ErrorAction SilentlyContinue
}
