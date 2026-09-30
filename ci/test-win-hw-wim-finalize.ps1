$ErrorActionPreference = 'Stop'
$finalize = Join-Path $PSScriptRoot '../provisioners/windows/win-hw-wim/scripts/finalize-vm.ps1'
$previousPassword = $env:WIM_BUILD_PASSWORD
$global:wimFinalizeTest = @{ Calls = @(); FailGuest = $false }
$stateFile = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())

function Invoke-Command {
    param($VMName, $Credential, $FilePath, $ErrorAction)
    if ($VMName -ne 'packer-nuc' -or $Credential.UserName -ne 'packer' -or
        (Split-Path -Leaf $FilePath) -ne 'sysprep-generalize.ps1') {
        throw 'Finalizer must use the build account and guest cleanup script over PowerShell Direct.'
    }
    $global:wimFinalizeTest.Calls += 'generalize'
    if ($global:wimFinalizeTest.FailGuest) { throw 'Guest cleanup failed' }
}
function Stop-VM {
    param($Name, $ErrorAction, [switch]$Force, [switch]$TurnOff)
    if ($Name -ne 'packer-nuc' -or $Force -or $TurnOff) { throw 'Shutdown must be graceful.' }
    $global:wimFinalizeTest.Calls += 'shutdown'
}

try {
    $env:WIM_BUILD_PASSWORD = 'test-only-password'
    $global:wimFinalizeTest.FailGuest = $false
    & $finalize
    if (($global:wimFinalizeTest.Calls -join ',') -ne 'generalize,shutdown') { throw 'Incorrect finalization order.' }

    $global:wimFinalizeTest.Calls = @()
    $global:wimFinalizeTest.FailGuest = $true
    $rejected = $false
    try { & $finalize } catch { $rejected = $_.Exception.Message -eq 'Guest cleanup failed' }
    if (-not $rejected -or ($global:wimFinalizeTest.Calls -join ',') -ne 'generalize') {
        throw 'Failed cleanup must propagate and prevent shutdown.'
    }

    $global:wimFinalizeTest.Calls = @()
    $env:WIM_BUILD_PASSWORD = $null
    $rejected = $false
    try { & $finalize } catch { $rejected = $_.Exception.Message -like 'WIM_BUILD_PASSWORD*' }
    if (-not $rejected -or $global:wimFinalizeTest.Calls.Count) { throw 'Missing credentials must fail before contacting the VM.' }
    # Execute the actual offline capture guard against representative State.ini files.
    $capture = Join-Path $PSScriptRoot '../provisioners/windows/win-hw-wim/scripts/capture-wim.ps1'
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($capture, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw 'Capture script has syntax errors.' }
    $guard = $ast.Find({ param($node)
        $node -is [System.Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text -like '*Refusing to capture*'
    }, $true)
    if (-not $guard) { throw 'Capture must verify generalization.' }
    $check = [scriptblock]::Create($guard.Extent.Text)
    foreach ($value in @('IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE', '"IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE"')) {
        Set-Content -LiteralPath $stateFile -Value "[State]`r`nImageState=$value"
        & $check
    }
    Set-Content -LiteralPath $stateFile -Value '[State]'
    $rejected = $false
    try { & $check } catch { $rejected = $true }
    if (-not $rejected) { throw 'Missing ImageState must prevent capture.' }
    Set-Content -LiteralPath $stateFile -Value 'ImageState="IMAGE_STATE_COMPLETE"'
    $rejected = $false
    try { & $check } catch { $rejected = $true }
    if (-not $rejected) { throw 'A specialized image must not be captured.' }
    Remove-Item -LiteralPath $stateFile
    $rejected = $false
    try { & $check } catch { $rejected = $true }
    if (-not $rejected) { throw 'Missing State.ini must prevent capture.' }
    'WIM finalization checks passed'
}
finally {
    $env:WIM_BUILD_PASSWORD = $previousPassword
    Remove-Variable -Name wimFinalizeTest -Scope Global
    Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
}
