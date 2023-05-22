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

variable "client_secret" {
  type      = string
  default   = "${env("client_secret")}"
  sensitive = true
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

source "azure-arm" "sig" {
  # WinRM
  communicator   = "winrm"
  winrm_insecure = "true"
  winrm_timeout  = "3m"
  winrm_use_ssl  = "true"
  winrm_username = "packer"

  # Authentication
  client_id       = "${var.client_id}"
  client_secret   = "${var.client_secret}"
  subscription_id = "${var.subscription_id}"
  tenant_id       = "${var.tenant_id}"

  # Source 
  os_type         = "Windows"
  image_publisher = "${var.image_publisher}"
  image_offer     = "${var.image_offer}"
  image_sku       = "${var.image_sku}"

  # Destination
  temp_resource_group_name           = "${var.temp_resource_group_name}"
  location                           = "Central US"
  managed_image_storage_account_type = "Standard_LRS"
  vm_size                            = "${var.vm_size}"
  managed_image_name                 = "${var.managed_image_name}"
  managed_image_resource_group_name  = "${var.resource_group}"
  async_resourcegroup_delete         = true

  # Shared image gallery https:github.com/mozilla-platform-ops/relops_infra_as_code/blob/master/terraform/azure_fx_nonci/worker-images.tf 
  shared_image_gallery_destination {
    subscription   = "${var.subscription_id}"
    resource_group = "${var.resource_group}"
    gallery_name   = "${var.gallery_name}"
    image_name     = "${var.image_name}"
    image_version  = "${var.image_version}"
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
  client_id       = "${var.client_id}"
  client_secret   = "${var.client_secret}"
  subscription_id = "${var.subscription_id}"
  tenant_id       = "${var.tenant_id}"

  # Source 
  os_type         = "Windows"
  image_publisher = "${var.image_publisher}"
  image_offer     = "${var.image_offer}"
  image_sku       = "${var.image_sku}"

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
  }

}

build {
  sources = [
      "source.azure-arm.nonsig",
      "source.azure-arm.sig"
    ]

   provisioner "powershell" {
    inline = ["$ErrorActionPreference='SilentlyContinue'", "Set-ExecutionPolicy unrestricted -force"]
   }

   provisioner "powershell" {
    elevated_password = ""
    elevated_user     = "SYSTEM"
    inline = ["New-Item -Name worker-images-scripts -Path C:/ -Type Directory -Force"]
   }

  provisioner "file" {
    source = "./scripts/"
    destination = "C:/worker-images-scripts"
  }

  provisioner "powershell" {
    elevated_password = ""
    elevated_user     = "SYSTEM"
    inline            = ["if (-not (Test-Path C:/worker-images-scripts)) {exit 1}"]
   }

   provisioner "powershell" {
    elevated_password = ""
    elevated_user     = "SYSTEM"
    environment_vars = [
        "worker_pool_id=${var.worker_pool_id}",
        "base_image=${var.base_image}",
        "src_organisation=${var.source_organization}",
        "src_Repository=${var.source_repository}",
        "src_Branch=${var.source_branch}"
    ]
    script            = ["scripts/bootrap_win.ps1"]
   }

   provisioner "powershell" {
    inline = ["$stage =  ((Get-ItemProperty -path HKLM:\\SOFTWARE\\Mozilla\\ronin_puppet).bootstrap_stage)", "If ($stage -ne 'complete') { exit 2}", "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Mozilla\\ronin_puppet' -name hand_off_ready -type  string -value yes", "Write-Output ' -> Waiting for GA Service (RdAgent) to start ...'", "while ((Get-Service RdAgent).Status -ne 'Running') { Start-Sleep -s 5 }", "Write-Output ' -> Waiting for GA Service (WindowsAzureTelemetryService) to start ...'", "while ((Get-Service WindowsAzureTelemetryService) -and ((Get-Service WindowsAzureTelemetryService).Status -ne 'Running')) { Start-Sleep -s 5 }", "Write-Output ' -> Waiting for GA Service (WindowsAzureGuestAgent) to start ...'", "while ((Get-Service WindowsAzureGuestAgent).Status -ne 'Running') { Start-Sleep -s 5 }", "Write-Output ' -> Sysprepping VM ...'", "if ( Test-Path $Env:SystemRoot\\system32\\Sysprep\\unattend.xml ) {Remove-Item $Env:SystemRoot\\system32\\Sysprep\\unattend.xml -Force}", "& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /oobe /generalize /quiet /quit", "while ($true) {start-sleep -s 10 ;$imageState = (Get-ItemProperty HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Setup\\State).ImageState; Write-Output $imageState; if ($imageState -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { break }}", "Write-Output ' -> Sysprep complete ...'"]
   }

}
