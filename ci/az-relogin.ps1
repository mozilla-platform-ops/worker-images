<#
.SYNOPSIS
  Re-authenticate the Azure CLI mid-job using the GitHub Actions OIDC token.

.DESCRIPTION
  The workflow authenticates once via azure/login (OIDC). That yields an Azure access
  token valid for ~1h that CANNOT be refreshed. The WIM bake step runs ~1h40m+, so by
  the time the completion marker appears the runner's token is dead and every
  `az ... --auth-mode login` call fails silently — the poll never detects completion
  (240-min timeout) and the always() teardown can't delete the VM (quota leak).

  This re-runs `az login` with a FRESH GitHub OIDC token. The job has
  `permissions: id-token: write`, so any step can mint a new OIDC JWT on demand; a token
  minted in the same job carries the same subject claim azure/login already succeeded
  with, so the federated login succeeds again and yields a fresh ~1h Azure token.

  Client/tenant/subscription are recovered from the CACHED az profile when not passed:
  `az account show` reads ~/.azure locally and works even after the access token has
  expired (SP login -> user.name is the app/client id). So callers need thread NO
  secrets through the workflow YAML — this fix stays entirely in the checked-out ci/
  scripts on the pipeline branch.

.NOTES
  Requires the GH OIDC request vars (present whenever the job has id-token: write):
  ACTIONS_ID_TOKEN_REQUEST_URL / ACTIONS_ID_TOKEN_REQUEST_TOKEN.
#>
[CmdletBinding()]
param(
    [string] $ClientId,
    [string] $TenantId,
    [string] $SubscriptionId
)
$ErrorActionPreference = 'Stop'

if (-not $env:ACTIONS_ID_TOKEN_REQUEST_URL -or -not $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN) {
    throw 'GH OIDC token endpoint unavailable (need permissions: id-token: write on the job).'
}

# Recover any missing identity fields from the cached az profile (survives token expiry).
if (-not ($ClientId -and $TenantId -and $SubscriptionId)) {
    $acct = az account show -o json 2>$null | ConvertFrom-Json
    if (-not $acct) { throw 'Cannot recover identity for OIDC re-login: no cached az profile (az account show returned nothing).' }
    if (-not $ClientId)       { $ClientId       = $acct.user.name }   # SP login: user.name = app/client id
    if (-not $TenantId)       { $TenantId       = $acct.tenantId }
    if (-not $SubscriptionId) { $SubscriptionId = $acct.id }
}
if (-not ($ClientId -and $TenantId -and $SubscriptionId)) {
    throw "Incomplete identity for OIDC re-login (client='$ClientId' tenant='$TenantId' sub='$SubscriptionId')."
}

# Mint a fresh GitHub OIDC token scoped to the Azure token-exchange audience.
$uri = "$($env:ACTIONS_ID_TOKEN_REQUEST_URL)&audience=api://AzureADTokenExchange"
$jwt = (Invoke-RestMethod -Uri $uri -Method GET -Headers @{ Authorization = "Bearer $($env:ACTIONS_ID_TOKEN_REQUEST_TOKEN)" }).value
if (-not $jwt) { throw 'GH OIDC token request returned an empty token.' }

az login --service-principal -u $ClientId -t $TenantId --federated-token $jwt --output none
if ($LASTEXITCODE -ne 0) { throw "az login (federated OIDC) failed with exit $LASTEXITCODE." }
az account set --subscription $SubscriptionId --output none
if ($LASTEXITCODE -ne 0) { throw "az account set --subscription '$SubscriptionId' failed with exit $LASTEXITCODE." }

Write-Host "  [az-relogin] re-authenticated to Azure via GH OIDC (subscription $SubscriptionId)"
