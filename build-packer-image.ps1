<#
This Source Code Form is subject to the terms of the Mozilla Public
License, v. 2.0. If a copy of the MPL was not distributed with this
file, You can obtain one at http://mozilla.org/MPL/2.0/.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string] 
    $Location,

    [string]
    $yaml_file
)


Install-Module powershell-yaml -force

$yaml_data = (Get-Content -Path (Join-Path -Path $PSScriptRoot\config -ChildPath $yaml_file) -Raw | ConvertFrom-Yaml)

# Get taskcluster secrets
$secret = (Invoke-WebRequest -Uri ('{0}/secrets/v1/secret/project/relops/image-builder/dev' -f $env:TASKCLUSTER_PROXY_URL) -UseBasicParsing | ConvertFrom-Json).secret;
# Random string for temp resource group. Prevent duplicate names in an event of a bad build
$random = (get-random -Maximum 999)
     
$Env:client_id = $secret.relops_azure.packer.app_id
$Env:client_secret = $secret.relops_azure.packer.password
$Env:tenant_id = $secret.relops_azure.tenant_id
$Env:image_publisher = $yaml_data.image.publisher
$Env:image_offer = $yaml_data.image.offer
$Env:image_sku = $yaml_data.image.sku
$Env:managed_image_resource_group_name = $yaml_data.azure.managed_image_resource_group_name
$Env:managed_image_storage_account_type = $yaml_data.azure.managed_image_storage_account_type
$Env:Project = $yaml_data.vm.tags.Project
#$Env:workerType = $yaml_data.vm.tags.workerType
$Env:base_image = $yaml_data.vm.tags.base_image
$Env:worker_pool_id = $yaml_data.vm.tags.worker_pool_id
#$worker_pool = ($yaml_data.vm.tags.worker_pool_id.replace('/','-'))
$worker_pool = $yaml_data.vm.tags.worker_pool_id
$Env:sourceOrganisation = $yaml_data.vm.tags.sourceOrganisation
$Env:sourceRepository = $yaml_data.vm.tags.sourceRepository
#$Env:sourceRevision = $yaml_data.vm.tags.sourceRevision
$Env:sourceBranch = $yaml_data.vm.tags.sourceBranch
$Env:bootstrapscript = ('https://raw.githubusercontent.com/{0}/{1}/{2}/provisioners/windows/azure/azure-bootstrap.ps1' -f $Env:sourceOrganisation, $Env:sourceRepository, $Env:sourceBranch)
$Env:deploymentId = $yaml_data.vm.tags.deploymentId
$Env:managed_by = $yaml_data.vm.tags.managed_by
$Env:location = $location
$Env:vm_size = $yaml_data.vm.size
$Env:disk_additional_size = $yaml_data.vm.disk_additional_size
$Env:managed_image_name = ('{0}-{1}-{2}-{3}' -f $worker_pool, $location, $yaml_data.image.sku, $yaml_data.vm.tags.deploymentId)
$Env:temp_resource_group_name = ('{0}-{1}-{2}-{3}-tmp3' -f $worker_pool, $location, $yaml_data.vm.tags.deploymentId, $random)
# alpha 2 is temp. Should be removed in the future
if (($yaml_file -like "*alpha2*" )) {
    $Env:managed_image_name = ('{0}-{1}-{2}-alpha2' -f $worker_pool, $location, $yaml_data.image.sku)
}
elseif (($yaml_file -like "*alpha*" )) {
    $Env:managed_image_name = ('{0}-{1}-{2}-alpha' -f $worker_pool, $location, $yaml_data.image.sku)
}
elseif (($yaml_file -like "*beta*" )) {
    $Env:managed_image_name = ('{0}-{1}-{2}-beta' -f $worker_pool, $location, $yaml_data.image.sku)
}
elseif (($yaml_file -like "*next*" )) {
    $Env:managed_image_name = ('{0}-{1}-{2}-next' -f $worker_pool, $location, $yaml_data.image.sku)
}
else {
    $Env:managed_image_name = ('{0}-{1}-{2}-{3}' -f $worker_pool, $location, $yaml_data.image.sku, $yaml_data.vm.tags.deploymentId)
}
if (($yaml_file -like "trusted*" )) {
    $Env:subscription_id = $secret.relops_azure.trusted_subscription_id
}
else {
    $Env:subscription_id = $secret.relops_azure.subscription_id
}


     (New-Object Net.WebClient).DownloadFile('https://cloud-image-builder.s3.us-west-2.amazonaws.com/packer.exe', '.\packer.exe')
#powershell .\packer.exe build -force $PSScriptRoot\packer-json-template.json
#.\packer.exe build -force $PSScriptRoot\packer-json-template.json
if (($yaml_file -like "*2012*" )) {
    .\packer.exe build -force $PSScriptRoot\2012-packer-json-template.json
}
else {
    .\packer.exe build -force $PSScriptRoot\packer-json-template.json
}
if ($LASTEXITCODE -ne 0) {
    exit 99
}