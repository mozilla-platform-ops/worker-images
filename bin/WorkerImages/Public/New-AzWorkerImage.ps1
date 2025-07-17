function New-AzWorkerImage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [String] $Key,

        [Parameter(Mandatory = $true)]
        [String] $Location,

        [Parameter(Mandatory = $true)]
        [String] $Client_ID,

        [Parameter(Mandatory = $true)]
        [String] $Subscription_ID,

        [Parameter(Mandatory = $true)]
        [String] $Tenant_ID,

        [Parameter(Mandatory = $true)]
        [String] $Application_ID,

        [Parameter(Mandatory = $true)]
        [String] $oidc_request_url,

        [Parameter(Mandatory = $true)]
        [String] $oidc_request_token,

        [Parameter(Mandatory = $false)]
        [String] $Team,

        [Switch] $PackerDebug
    )

    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module powershell-yaml -ErrorAction Stop

    switch ($Team) {
        "tceng" {
            $YamlPath = "config/tceng/$Key.yaml"
            $PackerHCLPath = "packer\tceng.azure.pkr.hcl"
            $ENV:PKR_VAR_Team_key = $Team

            $uuidBytes = [System.Text.Encoding]::UTF8.GetString(
                [System.Convert]::FromBase64String(
                    [System.Convert]::ToBase64String(
                        (1..256 | ForEach-Object { Get-Random -Minimum 97 -Maximum 122 } | ForEach-Object { [byte]$_ })
                    )
                )
            )
            $uuid = ($uuidBytes -replace '[^a-z0-9]', '')[0..19] -join ''
            $ENV:PKR_VAR_uuid = $uuid
        }
        default {
            $YamlPath = "config/$Key.yaml"
            $PackerHCLPath = "azure.pkr.hcl"
            if ($Team) {
                $ENV:PKR_VAR_Team_key = $Team
            }
        }
    }

    if (-not (Test-Path $YamlPath)) {
        throw "YAML file not found at: $YamlPath"
    }

    $YAML = ConvertFrom-Yaml (Get-Content $YamlPath -Raw)

    $ENV:PKR_VAR_config = $Key
    $ENV:PKR_VAR_location = $Location
    $ENV:PKR_VAR_image_key_name = $Key

    if ($YAML.image["publisher"]) { $ENV:PKR_VAR_image_publisher = $YAML.image["publisher"] }
    if ($YAML.image["offer"])     { $ENV:PKR_VAR_image_offer     = $YAML.image["offer"] }
    if ($YAML.image["sku"])       { $ENV:PKR_VAR_image_sku       = $YAML.image["sku"] }
    if ($YAML.image["version"])   { $ENV:PKR_VAR_image_version   = $YAML.image["version"] }

    if ($YAML.azure["managed_image_resource_group_name"]) {
        $ENV:PKR_VAR_resource_group = $YAML.azure["managed_image_resource_group_name"]
    }
    if ($YAML.azure["managed_image_storage_account_type"]) {
        $ENV:PKR_VAR_managed_image_storage_account_type = $YAML.azure["managed_image_storage_account_type"]
    }
    if ($YAML.azure["bootstrapscript"]) {
        $ENV:PKR_VAR_bootstrap_script = $YAML.azure["bootstrapscript"]
    }

    if ($YAML.vm["vm_size"])              { $ENV:PKR_VAR_vm_size              = $YAML.vm["vm_size"] }
    if ($YAML.vm["taskcluster_version"])  { $ENV:PKR_VAR_taskcluster_version  = $YAML.vm["taskcluster_version"] }
    if ($YAML.vm["taskcluster_ref"])      { $ENV:PKR_VAR_taskcluster_ref      = $YAML.vm["taskcluster_ref"] }
    if ($YAML.vm["taskcuster_repo"])      { $ENV:PKR_VAR_taskcuster_repo      = $YAML.vm["taskcuster_repo"] }
    if ($YAML.vm["providerType"])         { $ENV:PKR_VAR_provider_type        = $YAML.vm["providerType"] }

    if ($YAML.vm.tags["base_image"])        { $ENV:PKR_VAR_base_image        = $YAML.vm.tags["base_image"] }
    if ($YAML.vm.tags["sourceBranch"])      { $ENV:PKR_VAR_source_branch     = $YAML.vm.tags["sourceBranch"] }
    if ($YAML.vm.tags["sourceRepository"])  { $ENV:PKR_VAR_source_repository = $YAML.vm.tags["sourceRepository"] }
    if ($YAML.vm.tags["sourceOrganization"]){ $ENV:PKR_VAR_source_organization = $YAML.vm.tags["sourceOrganization"] }
    if ($YAML.vm.tags["deploymentId"])      { $ENV:PKR_VAR_deployment_id     = $YAML.vm.tags["deploymentId"] }
    if ($YAML.vm.tags["worker_pool_id"])    { $ENV:PKR_VAR_worker_pool_id    = $YAML.vm.tags["worker_pool_id"] }

    if ($YAML.vm.tags["worker_pool_id"] -and $YAML.vm.tags["deploymentId"]) {
        $ENV:PKR_VAR_temp_resource_group_name = ('{0}-{1}-{2}-pkrtmp' -f $YAML.vm.tags["worker_pool_id"], $YAML.vm.tags["deploymentId"], (Get-Random -Maximum 999))
    }

    $ENV:PKR_VAR_client_id          = $Client_ID
    $ENV:PKR_VAR_tenant_id          = $Tenant_ID
    $ENV:PKR_VAR_subscription_id    = $Subscription_ID
    $ENV:PKR_VAR_application_id     = $Application_ID
    $ENV:PKR_VAR_oidc_request_url   = $oidc_request_url
    $ENV:PKR_VAR_oidc_request_token = $oidc_request_token

    if ($Team -eq "tceng" -and $ENV:PKR_VAR_uuid) {
        $ENV:PKR_VAR_managed_image_name = "markco-test-imageset-$($ENV:PKR_VAR_uuid)-$Location"
    } else {
        switch -Wildcard ($Key) {
            "*alpha2*" {
                $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-{2}-alpha2' -f $YAML.vm.tags["worker_pool_id"], $Location, $ENV:PKR_VAR_image_sku)
            }
            "*alpha*" {
                $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-{2}-alpha' -f $YAML.vm.tags["worker_pool_id"], $Location, $ENV:PKR_VAR_image_sku)
            }
            Default {
                $ENV:PKR_VAR_managed_image_name = ('{0}-{1}-{2}-{3}' -f $YAML.vm.tags["worker_pool_id"], $Location, $ENV:PKR_VAR_image_sku, $YAML.vm.tags["deploymentId"])
            }
        }
    }

    Write-Host "Building $($ENV:PKR_VAR_managed_image_name) in $($ENV:PKR_VAR_temp_resource_group_name)"

    packer init $PackerHCLPath
    if ($PackerDebug) {
        packer build -debug --only azure-arm.nonsig -force $PackerHCLPath
    } else {
        packer build --only azure-arm.nonsig -force $PackerHCLPath
    }
}