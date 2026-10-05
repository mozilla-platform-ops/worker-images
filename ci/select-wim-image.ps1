[CmdletBinding()]
param([string]$Pool, [string]$Image)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($Pool -and $Pool -ne 'image-config') {
    Import-Module powershell-yaml
    $pools = (ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $root 'provisioners/windows/MDC1Windows/pools.yml') -Raw)).pools
    $matches = @($pools | Where-Object { $_.name -eq $Pool })
    if ($matches.Count -ne 1) { throw "Expected one pool named '$Pool'; found $($matches.Count)." }
    # Pool image names refer to matching WIM configs. Existing dated deployment
    # images can continue using the original image-config selector.
    $Image = [string]$matches[0].image
}
if ($Image -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]*$') { throw 'Invalid WIM image config name.' }
$config = Join-Path $root "provisioners/windows/win-hw-wim/config/$Image.yaml"
if (-not (Test-Path -LiteralPath $config -PathType Leaf)) { throw "WIM config not found: $config" }
return $Image
