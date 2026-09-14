packer {
  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = ">= 1.4.5"
    }
  }
}

variable "config" {
  type    = string
  default = "win11-25h2"
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.config))
    error_message = "Use a config name from config/foofrix without a path or extension."
  }
}

variable "image_version" {
  type = string
  validation {
    condition     = can(regex("^[0-9]+[.][0-9]+[.][0-9]+$", var.image_version))
    error_message = "Gallery versions must use numeric major.minor.patch format."
  }
}

variable "subscription_id" {
  type = string
}

variable "tenant_id" {
  type = string
}

variable "client_id" {
  type = string
}

variable "artifacts_directory" {
  type = string
}

variable "oidc_request_url" {
  type    = string
  default = env("ACTIONS_ID_TOKEN_REQUEST_URL")
}

variable "oidc_request_token" {
  type      = string
  default   = env("ACTIONS_ID_TOKEN_REQUEST_TOKEN")
  sensitive = true
}

locals {
  config = yamldecode(file(abspath("${path.root}/../config/foofrix/${var.config}.yaml")))
}

source "azure-arm" "foofrix" {
  client_id          = var.client_id
  tenant_id          = var.tenant_id
  subscription_id    = var.subscription_id
  oidc_request_url   = var.oidc_request_url
  oidc_request_token = var.oidc_request_token

  os_type         = "Windows"
  image_publisher = local.config.image.publisher
  image_offer     = local.config.image.offer
  image_sku       = local.config.image.sku
  image_version   = local.config.image.version

  location        = local.config.azure.location
  vm_size         = local.config.vm.size
  os_disk_size_gb = local.config.vm.os_disk_size_gb

  communicator   = "winrm"
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_username = "packer"
  winrm_timeout  = "10m"

  shared_image_gallery_destination {
    subscription         = var.subscription_id
    resource_group       = local.config.azure.resource_group
    gallery_name         = local.config.azure.gallery
    image_name           = local.config.azure.image_definition
    image_version        = var.image_version
    replication_regions  = local.config.azure.replication_regions
    storage_account_type = "Standard_LRS"
  }

  azure_tags = {
    project_name = "foofrix"
    managed_by   = "packer"
    config       = var.config
  }
}

build {
  sources = ["source.azure-arm.foofrix"]

  provisioner "powershell" {
    inline = ["New-Item -ItemType Directory -Force C:/FooFrix/artifacts, C:/Windows/Temp/foofrix-bootstrap | Out-Null"]
  }

  # Actions downloads the artifacts using OIDC; no storage credential enters the guest.
  provisioner "file" {
    source      = "${var.artifacts_directory}/"
    destination = "C:/FooFrix/artifacts"
  }

  provisioner "file" {
    source      = "${path.root}/../scripts/windows/foofrix/"
    destination = "C:/Windows/Temp/foofrix-bootstrap"
  }

  provisioner "powershell" {
    elevated_user     = "SYSTEM"
    elevated_password = ""
    inline            = ["& 'C:/Windows/Temp/foofrix-bootstrap/${local.config.bootstrap_script}'"]
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  provisioner "powershell" {
    script = "${path.root}/../tests/win/foofrix-base.tests.ps1"
  }

  provisioner "powershell" {
    inline = [
      "$ErrorActionPreference = 'Stop'",
      "Remove-Item $env:SystemRoot/System32/Sysprep/unattend.xml -Force -ErrorAction SilentlyContinue",
      "$process = Start-Process $env:SystemRoot/System32/Sysprep/Sysprep.exe -ArgumentList '/oobe /generalize /mode:vm /quiet /quit' -Wait -PassThru",
      "if ($process.ExitCode -ne 0) { throw ('Sysprep failed: ' + $process.ExitCode) }",
      "$deadline = (Get-Date).AddMinutes(15)",
      "while ((Get-ItemProperty 'HKLM:/SOFTWARE/Microsoft/Windows/CurrentVersion/Setup/State').ImageState -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { if ((Get-Date) -gt $deadline) { throw 'Sysprep timed out' }; Start-Sleep -Seconds 10 }"
    ]
  }

  post-processor "manifest" {
    output = "foofrix-manifest.json"
  }
}
