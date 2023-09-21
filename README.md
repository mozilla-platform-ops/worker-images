# Worker Images
This repository stores the code used to create a machine image for use in [Taskcluster](https://github.com/taskcluster). This repository uses Packer to provision the machine image, and the azure windows packer machine images use [Powershell Packer Provisioner](https://developer.hashicorp.com/packer/docs/provisioners/powershell) to call a custom script which bootstrap the OS using [Puppet](https://www.puppet.com/docs/puppet/7/puppet_index.html).

## High level Overview

This repository contains an opinionated way to run packer using configuration that is pre-defined in YAML format, along with integration tests for azure windows 11 virtual machine image used within [Taskcluster](https://github.com/taskcluster) using [Pester](https://pester.dev/). Images are deployed using either Github Actions or by running Packer locally. 

Within the Azure Packer HCL file, there are two `source` blocks, one for generating an [Azure Shared Image](https://learn.microsoft.com/en-us/azure/virtual-machines/shared-image-galleries?tabs=azure-cli) called `sig` (which stands for shared image gallery) and one for generating an Azure Managed Image called `non-sig`.

## Local development with Azure

There are two packer hcl files, one for Azure and one for GCP. To run packer locally for debugging purposes or to generate an image against the existing Packer HCL files, load the Powershell module and debug locally.

For example, to deploy a Windows 11 Alpha managed image (non shared image) for use in Azure and debug locally, follow these steps

```PowerShell
## Set the powershell gallery to trusted
Set-PSRepository PSGallery -InstallationPolicy Trusted
## Install Powershel YAML Module
Install-Module powershell-yaml -ErrorAction Stop
## Import workerimages powershell module
Import-Module ".\bin\WorkerImages\WorkerImages.psm1"
## Select the win11-64-2009-alpha key
$key = "win11-64-2009-alpha"
## Build the parameters to pass to the function
$Vars = @{
    Location        = "uksouth"
    Key             = "config/$key.yaml"
    Client_ID       = "foo" ## Update this with the app registration client id from azure
    Client_Secret   = "bar" ## Update this with the app registration client secret from azure
    Subscription_ID = "marco" ## Subscription ID to deploy to
    Tenant_ID       = "polo" ## Tenant ID to deploy to
}

## Run packer
New-AzWorkerImage @Vars -PackerDebug
```

## Local Development with GCP

WIP

## Acronyms

* GHA = Github Actions
* TC = Taskcluster, the CI pipeline to build and release Firefox.
* Worker Image = A machine image for use with Taskcluster that contains configuration from puppet.
* Ronin Puppet = Git repository that contains [puppet code](https://github.com/mozilla-platform-ops/ronin_puppet) which configures each worker image with specific configuration 
