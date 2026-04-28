Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$requiredVars = @(
    "CONFIG",
    "GITHUB_TOKEN",
    "CLIENT_ID",
    "OIDC_REQUEST_URL",
    "OIDC_REQUEST_TOKEN",
    "SUBSCRIPTION_ID",
    "TENANT_ID",
    "APPLICATION_ID"
)

foreach ($varName in $requiredVars) {
    if (-not [Environment]::GetEnvironmentVariable($varName)) {
        throw "$varName is not set."
    }
}

Import-Module ".\bin\WorkerImages\WorkerImages.psm1"

$vars = @{
    github_token = $env:GITHUB_TOKEN
    Key = $env:CONFIG
    Client_ID = $env:CLIENT_ID
    oidc_request_url = $env:OIDC_REQUEST_URL
    oidc_request_token = $env:OIDC_REQUEST_TOKEN
    Subscription_ID = $env:SUBSCRIPTION_ID
    Tenant_ID = $env:TENANT_ID
    Application_ID = $env:APPLICATION_ID
}

New-AzSharedWorkerImage @vars

if (-not $env:GITHUB_ENV) {
    throw "GITHUB_ENV is not set."
}

"sharedimageversion=$ENV:PKR_VAR_sharedimage_version" | Out-File -FilePath $env:GITHUB_ENV -Append
