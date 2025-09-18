// Inline PowerShell commands need a ";" inside quoted strings (except the last one)
// or Packer treats them as a single line.

packer {
  required_plugins {
    azure = {
      version = ">= 1.4.5"
      source  = "github.com/hashicorp/azure"
    }
  }
}

################################################################################
# Variables (all default to ENV so you can `export`/GitHub Actions `env:` them)
################################################################################

variable "config"             { default = env("config") }

# Base image
variable "image_publisher"    { default = env("image_publisher") }
variable "image_offer"        { default = env("image_offer") }
variable "image_sku"          { default = env("image_sku") }
variable "image_version"      { default = env("image_version") }

# Build settings
variable "vm_size"            { default = env("vm_size") }
variable "location"           { default = env("location") }
variable "temp_resource_group_name" { default = env("temp_resource_group_name") }

# Auth (OIDC via GitHub Actions or equivalent)
variable "client_id"          { default = env("client_id") }
variable "tenant_id"          { default = env("tenant_id") }
variable "subscription_id"    { default = env("subscription_id") }
variable "oidc_request_url"   { default = env("ACTIONS_ID_TOKEN_REQUEST_URL") }
variable "oidc_request_token" { default = env("ACTIONS_ID_TOKEN_REQUEST_TOKEN") }

# Shared Image Gallery destination
variable "sig_resource_group" { default = env("sig_resource_group") }
variable "sig_gallery_name"   { default = env("sig_gallery_name") }
variable "sig_image_name"     { default = env("sig_image_name") }
variable "sig_image_version"  { default = env("sig_image_version") } // e.g. 2025.09.18
# Comma-separated list of regions, e.g. "eastus,eastus2,westus3"
variable "replication_regions_csv" { default = env("replication_regions") }

# Bootstrap script (path on your repo/runner)
# Example: "scripts/windows/bootstrap.ps1" or just "bootstrap.ps1"
variable "bootstrap_script"   { default = env("bootstrap_script") }

# Optional tagging
variable "deployment_id"      { default = env("deployment_id") }
variable "managed_by"         { default = env("managed_by") }

################################################################################
# Locals
################################################################################
locals {
  base_image_urn     = "${var.image_publisher}:${var.image_offer}:${var.image_sku}:${var.image_version}"
  sbom_name          = var.config
  replication_regions = compact([for r in split(",", var.replication_regions_csv) : trimspace(r)])
}

################################################################################
# Azure SIG Source (Windows)
################################################################################
source "azure-arm" "sig" {
  # WinRM
  communicator   = "winrm"
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_timeout  = "3m"
  winrm_username = "packer"

  # Auth (OIDC)
  oidc_request_url   = var.oidc_request_url
  oidc_request_token = var.oidc_request_token
  client_id          = var.client_id
  subscription_id    = var.subscription_id
  tenant_id          = var.tenant_id

  # Source image
  os_type         = "Windows"
  image_publisher = var.image_publisher
  image_offer     = var.image_offer
  image_sku       = var.image_sku
  image_version   = var.image_version

  # Build infra
  location                   = var.location
  temp_resource_group_name   = var.temp_resource_group_name
  vm_size                    = var.vm_size
  async_resourcegroup_delete = true

  # Shared Image Gallery destination
  shared_image_gallery_destination {
    subscription        = var.subscription_id
    resource_group      = var.sig_resource_group
    gallery_name        = var.sig_gallery_name
    image_name          = var.sig_image_name
    image_version       = var.sig_image_version
    replication_regions = local.replication_regions
  }

  # Tags
  azure_tags = {
    base_image    = local.base_image_urn
    deployment_id = var.deployment_id
    managed_by    = coalesce(var.managed_by, "packer")
    config        = var.config
  }
}

################################################################################
# Build
################################################################################
build {
  sources = ["source.azure-arm.sig"]

  # Push your bootstrap script onto the VM
  provisioner "file" {
    source      = "${path.root}/${var.bootstrap_script}"
    destination = "C:/Windows/Temp/bootstrap.ps1"
  }

  # Run bootstrap
  provisioner "powershell" {
    inline = [
      "& 'C:/Windows/Temp/bootstrap.ps1' -MyCloud 'azure';"
    ]
  }

  # Optional reboot if your bootstrap enables features that need it
  provisioner "windows-restart" {}

  # Generalize & shut down for imaging
  provisioner "powershell" {
    inline = [
      "Write-Host '=== Generalizing image with Sysprep ===';",
      "& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /generalize /oobe /shutdown /quiet"
    ]
  }
}