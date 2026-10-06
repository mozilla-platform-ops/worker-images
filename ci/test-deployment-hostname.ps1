# Run with powershell.exe -NoProfile -File ci/test-deployment-hostname.ps1
# DNS is mocked; the deployment script is parsed but never executed.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'provisioners/windows/MDC1Windows/OS-deploy.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$function = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-DeploymentHostname' }, $true)
Invoke-Expression $function.Extent.Text
if ($ast.Extent.Text -notmatch '\$ResolvedName = Resolve-DeploymentHostname -IPAddresses @\(\$IPAddress\)') { throw 'Deployment must use the multiple-IP resolver.' }
function Assert-Fails([scriptblock]$Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'Expected failure.' }
}
function Resolve-DnsName {
    param($Name, $Server, $Type, $ErrorAction)
    if ($Name -isnot [string] -or $Server -ne '10.48.75.120' -or $Type -ne 'PTR') { throw 'Incorrect reverse DNS request.' }
    if (-not $script:ptrRecords.ContainsKey($Name)) { throw 'DNS name does not exist.' }
    return [pscustomobject]@{ NameHost = $script:ptrRecords[$Name] }
}
$script:ptrRecords = @{ '10.49.64.99' = 'a11y.wintest2.releng.mdc1.mozilla.com.' }
if ((Resolve-DeploymentHostname @('10.49.64.99', '10.49.67.195')) -ne 'a11y.wintest2.releng.mdc1.mozilla.com') {
    throw 'Two IP addresses with one PTR record must resolve the deployment hostname.'
}
if ((Resolve-DeploymentHostname @('10.49.64.99')) -ne 'a11y.wintest2.releng.mdc1.mozilla.com') { throw 'Single-IP resolution changed.' }
$script:ptrRecords['10.49.67.195'] = 'A11Y.wintest2.releng.mdc1.mozilla.com'
if ((Resolve-DeploymentHostname @('10.49.64.99', '10.49.67.195')) -ne 'a11y.wintest2.releng.mdc1.mozilla.com') { throw 'Equivalent PTR records must resolve once.' }
$script:ptrRecords['10.49.67.195'] = 'other.example.com'
Assert-Fails { Resolve-DeploymentHostname @('10.49.64.99', '10.49.67.195') }
Assert-Fails { Resolve-DeploymentHostname @('10.49.67.196') }
Remove-Item Function:\Resolve-DnsName
Write-Host 'Deployment hostname checks passed.'
