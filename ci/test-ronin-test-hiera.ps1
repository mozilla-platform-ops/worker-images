# Run with pwsh -NoProfile -File ci/test-ronin-test-hiera.ps1.
$ErrorActionPreference = 'Stop'
Import-Module powershell-yaml
. "$PSScriptRoot/../scripts/windows/CustomFunctions/Bootstrap/Public/Invoke-RoninTest.ps1"

# Test the real runner without starting Pester or reading the Windows filesystem.
function Write-Log {}
function Test-Path($Path) { return $Path -notlike '*windows-pools*' -or $script:HasPool }
function Get-Content($Path, [switch]$Raw) {
    switch -Wildcard ($Path) {
        '*roles*' { 'role: present' }
        '*Windows.yaml' { 'windows: {taskcluster: {task_drive: "D:", version: "110.0.0"}}' }
        '*Config*' { 'vm: {tags: {worker_pool_id: alpha}}\ntests: [example.tests.ps1]' -replace '\\n', "`n" }
        '*windows-pools*' {
            if ($Path -ne 'C:\ronin\data\windows-pools\alpha.yaml') { throw "Wrong pool path: $Path" }
            'windows: {taskcluster: {task_drive: "C:"}}'
        }
        default { throw "Unexpected path: $Path" }
    }
}
function Get-ChildItem { return @{ FullName = 'example.tests.ps1' } }
function New-PesterContainer($Path, $Data) { $script:Actual = $Data.Hiera }
function New-PesterConfiguration { return @{ Run = @{}; TestResult = @{}; Output = @{} } }
function Invoke-Pester {}

foreach ($script:HasPool in @($false, $true)) {
    Invoke-RoninTest -Role test -Config alpha
    $expectedDrive = if ($script:HasPool) { 'C:' } else { 'D:' }
    if ($script:Actual.windows.taskcluster.task_drive -ne $expectedDrive -or
        $script:Actual.windows.taskcluster.version -ne '110.0.0' -or
        $script:Actual.role -ne 'present') { throw 'Hiera merge failed' }
}
Write-Output 'PASS: optional pool data takes priority and preserves existing settings.'
