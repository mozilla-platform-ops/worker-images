# Worker Images
This repository stores the code used to create a machine image for use in [Taskcluster](https://github.com/taskcluster). This repository uses Packer to provision the machine image, and the azure windows packer machine images use [Powershell Packer Provisioner](https://developer.hashicorp.com/packer/docs/provisioners/powershell) to call a custom script which bootstrap the OS using [Puppet](https://www.puppet.com/docs/puppet/7/puppet_index.html).

## High level Overview

This repository contains an opinionated way to run packer using configuration that is pre-defined in YAML format, along with integration tests for azure windows 11 virtual machine image used within [Taskcluster](https://github.com/taskcluster) using [Pester](https://pester.dev/). Images are deployed using either Github Actions or by running Packer locally. 

Within the Azure Packer HCL file, there are two `source` blocks, one for generating an [Azure Shared Image](https://learn.microsoft.com/en-us/azure/virtual-machines/shared-image-galleries?tabs=azure-cli) called `sig` (which stands for shared image gallery) and one for generating an Azure Managed Image called `non-sig`.

## Local development with Azure

There are two packer hcl files, one for Azure and one for GCP. To run packer locally for debugging purposes or to generate an image against the existing Packer HCL files, export the necessary variables and then use a variant of `packer build` to generate a machine image.

For example, to deploy a Windows 11 managed image (non shared image) for use in Azure and debug locally, follow these steps

```PowerShell
$ENV:PKR_VAR_client_id = "foo" ## client id for the app registration used to provision azure images
$ENV:PKR_VAR_client_secret = "barr" ## client secret for the app registration used to provision azure images
$ENV:PKR_VAR_subscription_id = "aaaa" ## azure subscription where the image will be deployed to
$ENV:PKR_VAR_tenant_id = "bbb" ## azure tenant where the azure subscription lives
$ENV:PKR_VAR_image_publisher = "MicrosoftWindowsDesktop" ## Azure Image Publisher where Windows 11 SKU lives
$ENV:PKR_VAR_image_offer = "Windows-11" ## Azure image offer for Windows 11
$ENV:PKR_VAR_image_sku = "win11-22h2-avd" ## Azure image sku for Windows 11
$ENV:PKR_VAR_temp_resource_group_name = 'win11-64-2009-pkrtmp-repalcemen' ## Name of the resource group to build the image in
$ENV:PKR_VAR_vm_size = "Standard_F8s_v2" ## The VM size that is used to build the image
$ENV:PKR_VAR_managed_image_name = ('{0}-{1}-alpha' -f "win11-64-2009", $ENV:PKR_VAR_image_sku) ## The name of the Azure managed image
$ENV:PKR_VAR_resource_group = "rg-packer-worker-images" ## The managed image resource group that contains the Azure managed image
$ENV:PKR_VAR_gallery_name = "ronin_t_windows11_64_2009_alpha" ## Only required if you're creating a Shared Image in a gallery
$ENV:PKR_VAR_image_name = "win11-64-2009-alpha" ## Only required if you're creating a Shared Image in a gallery
$ENV:PKR_VAR_sharedimage_version = "1.0.0" ## Only required if you're creating a Shared Image in a gallery
$ENV:PKR_VAR_base_image = "win11642009azure" ## The azure tag for base_image
$ENV:PKR_VAR_deployment_id = "669c5d9" ## The azure tag for the commmit hash used with puppet
$ENV:PKR_VAR_source_branch = "cloud_windows" ## The azure tag for the branch used with puppet
$ENV:PKR_VAR_source_organization = "mozilla-platform-ops" ## The azure tag for the organization used with puppet
$ENV:PKR_VAR_source_repository = "ronin_puppet" ## The azure tag for the repository used with puppet
$ENV:PKR_VAR_worker_pool_id = "win11-64-2009" ## The azure tag for the taskcluster worker pool id
$ENV:PKR_VAR_image_sku_version = "22621.1555.230329" ## The image sku for windows 11
$ENV:PKR_VAR_location = "Central US" ## The region where the managed image will be built.

packer build --only azure-arm.nonsig -force azure.pkr.hcl -debug
```

The `--only azure-arm.nonsig` selects the packer `source` block that deploys a non-shared image.

## Local Development with GCP

WIP

## Acronyms

* GHA = Github Actions
* TC = Taskcluster, the CI pipeline to build and release Firefox.
* Worker Image = A machine image for use with Taskcluster that contains configuration from puppet.
* Ronin Puppet = Git repository that contains [puppet code](https://github.com/mozilla-platform-ops/ronin_puppet) which configures each worker image with specific configuration 
