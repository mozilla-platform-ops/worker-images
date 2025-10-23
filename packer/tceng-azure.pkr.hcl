// Inline Powershell Commands need a ";" inside quotations. Except for last command.
// Without it Packer will treat all commands as single line.

packer {
  required_plugins {
    azure = {
      version = ">= 1.4.5"
      source  = "github.com/hashicorp/azure"
    }
  }
}

variable "config"               { default = env("config") }
variable "image_publisher"      { default = env("image_publisher") }
variable "image_offer"          { default = env("image_offer") }
variable "image_sku"            { default = env("image_sku") }
variable "image_version"        { default = env("image_version") }
variable "vm_size"              { default = env("vm_size") }
variable "location"             { default = env("location") }

variable "managed_image_name"                { default = env("managed_image_name") }
variable "resource_group"                    { default = env("resource_group") }
variable "managed_image_resource_group_name" { default = env("managed_image_resource_group_name") }

variable "sharedimage_version"   { default = env("sharedimage_version") }
variable "bootstrap_script"      { default = env("bootstrap_script") }

variable "taskcluster_ref"       { default = env("taskcluster_ref") }
variable "taskcluster_repo"      { default = env("taskcluster_repo") }
variable "provider_type"         { default = env("provider_type") }

variable "client_id"            { default = env("client_id") }
variable "tenant_id"            { default = env("tenant_id") }
variable "subscription_id"      { default = env("subscription_id") }
variable "oidc_request_url"     { default = env("ACTIONS_ID_TOKEN_REQUEST_URL") }
variable "oidc_request_token"   { default = env("ACTIONS_ID_TOKEN_REQUEST_TOKEN") }

variable "temp_resource_group_name" {
  default = env("temp_resource_group_name")
}

locals {
  sbom_name = var.config
}

source "azure-arm" "nonsig" {
  communicator                 = "winrm"
  winrm_insecure              = true
  winrm_timeout               = "3m"
  winrm_use_ssl               = true
  winrm_username              = "packer"

  oidc_request_url            = var.oidc_request_url
  oidc_request_token          = var.oidc_request_token
  client_id                   = var.client_id
  subscription_id             = var.subscription_id
  tenant_id                   = var.tenant_id

  os_type                     = "Windows"
  image_publisher             = var.image_publisher
  image_offer                 = var.image_offer
  image_sku                   = var.image_sku
  image_version               = var.image_version

  location                    = var.location
  temp_resource_group_name   = var.temp_resource_group_name
  vm_size                     = var.vm_size
  async_resourcegroup_delete = true

  managed_image_name                 = var.managed_image_name
  managed_image_resource_group_name = var.managed_image_resource_group_name

  azure_tags = {
    base_image     = "${var.image_publisher}:${var.image_offer}:${var.image_sku}:${var.image_version}"
    managed_by     = "packer"
    deployment_id  = var.sharedimage_version
  }
}

build {
  sources = ["source.azure-arm.nonsig"]

  provisioner "file" {
    source      = "${path.root}/../scripts/windows/tceng/${var.bootstrap_script}.ps1"
    destination = "C:/Windows/Temp/bootstrap.ps1"
  }

  provisioner "powershell" {
    inline = [
      "& 'C:/Windows/Temp/bootstrap.ps1' -MY_CLOUD azure -TASKCLUSTER_REF '${var.taskcluster_ref}' ;"
    ]
  }

  provisioner "windows-restart" {}

  provisioner "powershell" {
    inline = [
      "& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /generalize /oobe /shutdown /quiet"
    ]
  }
}
