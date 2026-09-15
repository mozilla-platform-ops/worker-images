$ErrorActionPreference = 'Stop'
Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -ErrorAction Stop
$root = Split-Path $PSScriptRoot -Parent
$files = git -C $root ls-files -- bin scripts provisioners ci
if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate tracked PowerShell sources.' }
$files = @($files | Where-Object { $_ -match '\.(ps1|psm1|psd1)$' -and $_ -notmatch '^ci/test[-_]' })
$findings = @(
    foreach ($file in $files) {
        # A tracked file may be deleted in an unstaged local edit.
        $path = Join-Path $root $file
        if (Test-Path -LiteralPath $path) {
            Invoke-ScriptAnalyzer -Path $path -Settings "$root/PSScriptAnalyzerSettings.psd1"
        }
    }
)
if ($findings) {
    $findings | Format-Table ScriptName, Line, RuleName, Message -Wrap
    throw "PSScriptAnalyzer found $($findings.Count) production-script issue(s)."
}
Write-Host "PSScriptAnalyzer: checked $($files.Count) tracked production files."
