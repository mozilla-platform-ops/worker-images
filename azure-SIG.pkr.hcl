packer {
  required_plugins {
    azure = {
      version = ">= 1.4.5"
      source  = "github.com/hashicorp/azure"
    }
  }
}

locals {
  sbom_name = var.config
}

variable "base_image" {
  type    = string
  default = "${env("base_image")}"
}

variable "bootstrap_script" {
  type    = string
  default = "${env("bootstrap_script")}"
}

variable "client_id" {
  type    = string
  default = "${env("client_id")}"
}

variable "oidc_request_url" {
  type    = string
  default = "${env("ACTIONS_ID_TOKEN_REQUEST_URL")}"
}

variable "oidc_request_token" {
  type    = string
  default = "${env("ACTIONS_ID_TOKEN_REQUEST_TOKEN")}"
}

variable "deployment_id" {
  type    = string
  default = "${env("deployment_id")}"
}

variable "disk_additional_size" {
  type    = string
  default = "${env("disk_additional_size")}"
}

variable "image_offer" {
  type    = string
  default = "${env("image_offer")}"
}

variable "image_publisher" {
  type    = string
  default = "${env("image_publisher")}"
}

variable "image_sku" {
  type    = string
  default = "${env("image_sku")}"
}

variable "image_version" {
  type    = string
  default = "${env("image_version")}"
}

variable "sharedimage_version" {
  type    = string
  default = "${env("sharedimage_version")}"
}

variable "location" {
  type    = string
  default = "${env("location")}"
}

variable "managed-by" {
  type    = string
  default = "${env("managed_by")}"
}

variable "managed_image_name" {
  type    = string
  default = "${env("managed_image_name")}"
}

variable "managed_image_storage_account_type" {
  type    = string
  default = "${env("managed_image_storage_account_type")}"
}

variable "source_branch" {
  type    = string
  default = "${env("source_branch")}"
}

variable "source_organization" {
  type    = string
  default = "${env("source_organization")}"
}

variable "source_repository" {
  type    = string
  default = "${env("sourceRepository")}"
}

variable "subscription_id" {
  type    = string
  default = "${env("subscription_id")}"
}

variable "tenant_id" {
  type    = string
  default = "${env("tenant_id")}"
}

variable "vm_size" {
  type    = string
  default = "${env("vm_size")}"
}

variable "worker_pool_id" {
  type    = string
  default = "${env("worker_pool_id")}"
}

variable "resource_group" {
  type    = string
  default = "${env("resource_group")}"
}

variable "temp_resource_group_name" {
  type    = string
  default = "${env("temp_resource_group_name")}"
}

variable "gallery_name" {
  type    = string
  default = "${env("gallery_name")}"
}

variable "image_name" {
  type    = string
  default = "${env("image_name")}"
}

variable "application_id" {
  type    = string
  default = "${env("application_id")}"
}

variable "config" {
  type    = string
  default = "${env("config")}"
}

source "azure-arm" "sig" {
  # WinRM
  communicator   = "winrm"
  winrm_insecure = "true"
  winrm_timeout  = "3m"
  winrm_use_ssl  = "true"
  winrm_username = "packer"

  # Authentication
  oidc_request_url   = "${var.oidc_request_url}"
  oidc_request_token = "${var.oidc_request_token}"
  client_id          = "${var.client_id}"
  subscription_id    = "${var.subscription_id}"
  tenant_id          = "${var.tenant_id}"

  # Source 
  os_type         = "Windows"
  image_publisher = "${var.image_publisher}"
  image_offer     = "${var.image_offer}"
  image_sku       = "${var.image_sku}"
  image_version   = "${var.image_version}"

  # Destination
  temp_resource_group_name           = "${var.temp_resource_group_name}"
  location                           = "Central US"
  vm_size                            = "${var.vm_size}"
  async_resourcegroup_delete         = true

  # Shared image gallery https:github.com/mozilla-platform-ops/relops_infra_as_code/blob/master/terraform/azure_fx_nonci/worker-images.tf 
  shared_image_gallery_destination {
    subscription   = "${var.subscription_id}"
    resource_group = "${var.resource_group}"
    gallery_name   = "${var.gallery_name}"
    image_name     = "${var.image_name}"
    image_version  = "${var.sharedimage_version}"
    replication_regions = [
      "centralindia",
      "eastus",
      "eastus2",
      "northcentralus",
      "northeurope",
      "southindia",
      "southcentralus",
      "westus",
      "westus2",
      "westus3"
    ]
  }

  # Tags
  azure_tags = {
    base_image         = "${var.base_image}"
    deploymentId       = "${var.deployment_id}"
    sourceBranch       = "${var.source_branch}"
    sourceOrganisation = "${var.source_organization}"
    sourceRepository   = "${var.source_repository}"
    worker_pool_id     = "${var.worker_pool_id}"
  }
}

source "azure-arm" "nonsig" {
  # WinRM
  communicator   = "winrm"
  winrm_insecure = "true"
  winrm_timeout  = "3m"
  winrm_use_ssl  = "true"
  winrm_username = "packer"

  # Authentication
  oidc_request_url   = "${var.oidc_request_url}"
  oidc_request_token = "${var.oidc_request_token}"
  client_id          = "${var.client_id}"
  subscription_id    = "${var.subscription_id}"
  tenant_id          = "${var.tenant_id}"

  # Source 
  os_type         = "Windows"
  image_publisher = "${var.image_publisher}"
  image_offer     = "${var.image_offer}"
  image_sku       = "${var.image_sku}"
  image_version   = "${var.image_version}"

  # Destination
  temp_resource_group_name           = "${var.temp_resource_group_name}"
  location                           = "${var.location}"
  managed_image_storage_account_type = "Standard_LRS"
  vm_size                            = "${var.vm_size}"
  managed_image_name                 = "${var.managed_image_name}"
  managed_image_resource_group_name  = "${var.resource_group}"
  async_resourcegroup_delete         = true

  # Tags
  azure_tags = {
    base_image         = "${var.base_image}"
    deploymentId       = "${var.deployment_id}"
    sourceBranch       = "${var.source_branch}"
    sourceOrganisation = "${var.source_organization}"
    sourceRepository   = "${var.source_repository}"
    worker_pool_id     = "${var.worker_pool_id}"
    image_version      = "${var.image_version}"
  }

}

build {
  sources = [
    "source.azure-arm.nonsig",
    "source.azure-arm.sig"
  ]

  provisioner "powershell" {
    inline = [
      "$ErrorActionPreference='SilentlyContinue'",
      "Set-ExecutionPolicy unrestricted -force"
    ]
  }

  provisioner "file" {
    source      = "${path.root}/scripts/windows/CustomFunctions/Bootstrap"
    destination = "C:/Windows/System32/WindowsPowerShell/v1.0/Modules/"
  }

  provisioner "powershell" {
    elevated_password = ""
    elevated_user     = "SYSTEM"
    inline = [
      "$null = New-Item -Name 'Tests' -Path C:/ -Type Directory -Force",
      "$null = New-Item -Name 'Config' -Path C:/ -Type Directory -Force"
    ]
  }

  provisioner "file" {
    source      = "${path.cwd}/tests/win/"
    destination = "C:/Tests"
  }

  provisioner "file" {
    source      = "${path.cwd}/config/"
    destination = "C:/Config"
  }

  provisioner "powershell" {
    elevated_password = ""
    elevated_user     = "SYSTEM"
    environment_vars = [
      "worker_pool_id=${var.worker_pool_id}",
      "base_image=${var.base_image}",
      "src_organisation=${var.source_organization}",
      "src_Repository=${var.source_repository}",
      "src_Branch=${var.source_branch}",
      "deploymentId=${var.deployment_id}",
      "client_id=${var.client_id}",
      "tenant_id=${var.tenant_id}",
      "application_id=${var.application_id}",
      "config=${var.config}"
    ]
    inline = [
      "Import-Module BootStrap -Force",
      "Disable-AntiVirus",
      "Set-Logging",
      "Install-AzPreReq",
      "Set-RoninRegOptions"
    ]
  }

  provisioner "windows-restart" {
  }

  provisioner "powershell" {
    elevated_password = ""
    elevated_user     = "SYSTEM"
    environment_vars = [
      "worker_pool_id=${var.worker_pool_id}",
      "base_image=${var.base_image}",
      "src_organisation=${var.source_organization}",
      "src_Repository=${var.source_repository}",
      "src_Branch=${var.source_branch}",
      "deploymentId=${var.deployment_id}"
    ]
    inline = [
      "Import-Module BootStrap -Force",
      "Set-AzRoninRepo"
    ]
  }

  provisioner "powershell" {
    elevated_password = ""
    elevated_user     = "SYSTEM"
    environment_vars = [
      "worker_pool_id=${var.worker_pool_id}",
      "base_image=${var.base_image}",
      "src_organisation=${var.source_organization}",
      "src_Repository=${var.source_repository}",
      "src_Branch=${var.source_branch}",
      "deploymentId=${var.deployment_id}",
      "client_id=${var.client_id}",
      "tenant_id=${var.tenant_id}",
      "application_id=${var.application_id}"
    ]
    inline = [
      "Import-Module BootStrap -Force",
      "Start-AzRoninPuppet"
    ]
    valid_exit_codes = [
      0,
      2
    ]
  }

  provisioner "powershell" {
    elevated_password = ""
    elevated_user     = "SYSTEM"
    inline = [
      "Import-Module BootStrap -Force",
      "Disable-Services"
    ]
  }

  provisioner "powershell" {
    elevated_password = ""
    elevated_user     = "SYSTEM"
    environment_vars = [
      "worker_pool_id=${var.worker_pool_id}",
      "base_image=${var.base_image}",
      "src_organisation=${var.source_organization}",
      "src_Repository=${var.source_repository}",
      "src_Branch=${var.source_branch}",
      "deploymentId=${var.deployment_id}",
      "config=${var.config}"
    ]
    inline = [
      "Import-Module BootStrap -Force",
      "Set-PesterVersion",
      "Set-YAMLModule",
      "Invoke-RoninTest -Role $ENV:base_image -Config $ENV:config"
    ]
    valid_exit_codes = [
      0
    ]
  }

  provisioner "powershell" {
    elevated_password = ""
    elevated_user     = "SYSTEM"
    environment_vars = [
      "worker_pool_id=${var.worker_pool_id}",
      "base_image=${var.base_image}",
      "src_organisation=${var.source_organization}",
      "src_Repository=${var.source_repository}",
      "src_Branch=${var.source_branch}",
      "deploymentId=${var.deployment_id}",
      "config=${var.config}",
      "client_id=${var.client_id}",
      "tenant_id=${var.tenant_id}",
      "application_id=${var.application_id}"
    ]
    inline = [
      "Import-Module BootStrap -Force",
      "Set-MarkdownPSModule",
      "Set-ReleaseNotes -Config $ENV:config"
    ]
  }

  provisioner "file" {
    destination = "${path.root}/${local.sbom_name}.md"
    source      = "C:/${local.sbom_name}.md"
    direction   = "download"
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  provisioner "powershell" {
    inline = [
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Mozilla\\ronin_puppet' -Name hand_off_ready -Type string -Value yes",
      "Write-host '=== Azure image build completed successfully ==='",
      "Write-host '=== Generalising the image ... ==='",
      "& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /generalize /oobe /quit",
      "while ($true) { $imageState = Get-ItemProperty HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Setup\\State | Select ImageState; if($imageState.ImageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { Write-Output $imageState.ImageState; Start-Sleep -s 15 } else { break } }"
    ]
  }

}
