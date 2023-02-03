source "azure-arm" "this" {
  async_resourcegroup_delete = true
  azure_tags = {
    Project            = "${var.Project}"
    base_image         = "${var.base_image}"
    deploymentId       = "${var.deploymentId}"
    sourceBranch       = "${var.sourceBranch}"
    sourceOrganisation = "${var.sourceOrganisation}"
    sourceRepository   = "${var.sourceRepository}"
    worker_pool_id     = "${var.worker_pool_id}"
  }
  client_id                              = "${var.client_id}"
  client_secret                          = "${var.client_secret}"
  communicator                           = "winrm"
  image_offer                            = "${var.image_offer}"
  image_publisher                        = "${var.image_publisher}"
  image_sku                              = "${var.image_sku}"
  location                               = "${var.location}"
  managed_image_name                     = "${var.managed_image_name}"
  managed_image_resource_group_name      = "${var.managed_image_resource_group_name}"
  managed_image_storage_account_type     = "${var.managed_image_storage_account_type}"
  os_type                                = "Windows"
  private_virtual_network_with_public_ip = "True"
  subscription_id                        = "${var.subscription_id}"
  temp_resource_group_name               = "${var.temp_resource_group_name}"
  tenant_id                              = "${var.tenant_id}"
  virtual_network_name                   = ""
  virtual_network_resource_group_name    = ""
  virtual_network_subnet_name            = ""
  vm_size                                = "${var.vm_size}"
  winrm_insecure                         = "true"
  winrm_timeout                          = "3m"
  winrm_use_ssl                          = "true"
  winrm_username                         = "packer"
}


build {
  sources = ["source.azure-arm.this"]

  provisioner "powershell" {
    inline = ["$ErrorActionPreference='SilentlyContinue'", "Set-ExecutionPolicy unrestricted -force"]
  }

  provisioner "powershell" {
    elevated_password = ""
    elevated_user     = "SYSTEM"
    inline            = ["Invoke-Expression ((New-Object -TypeName net.webclient).DownloadString('${var.bootstrapscript}'))"]
  }

  provisioner "windows-restart" {
  }

  provisioner "powershell" {
    elevated_password = ""
    elevated_user     = "SYSTEM"
    inline            = ["Invoke-Expression ((New-Object -TypeName net.webclient).DownloadString('${var.bootstrapscript}'))"]
  }

  provisioner "windows-restart" {
  }

  provisioner "powershell" {
    elevated_password = ""
    elevated_user     = "SYSTEM"
    inline            = ["Invoke-Expression ((New-Object -TypeName net.webclient).DownloadString('${var.bootstrapscript}'))"]
  }

  provisioner "windows-restart" {
  }

  provisioner "powershell" {
    elevated_password = ""
    elevated_user     = "SYSTEM"
    inline            = ["Invoke-Expression ((New-Object -TypeName net.webclient).DownloadString('${var.bootstrapscript}'))"]
  }

  provisioner "windows-restart" {
  }

  provisioner "powershell" {
    elevated_password = ""
    elevated_user     = "SYSTEM"
    inline            = ["Invoke-Expression ((New-Object -TypeName net.webclient).DownloadString('${var.bootstrapscript}'))"]
  }

  provisioner "powershell" {
    inline = ["$stage =  ((Get-ItemProperty -path HKLM:\\SOFTWARE\\Mozilla\\ronin_puppet).bootstrap_stage)", "If ($stage -ne 'complete') { exit 2}", "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Mozilla\\ronin_puppet' -name hand_off_ready -type  string -value yes", "Write-Output ' -> Waiting for GA Service (RdAgent) to start ...'", "while ((Get-Service RdAgent).Status -ne 'Running') { Start-Sleep -s 5 }", "Write-Output ' -> Waiting for GA Service (WindowsAzureTelemetryService) to start ...'", "while ((Get-Service WindowsAzureTelemetryService) -and ((Get-Service WindowsAzureTelemetryService).Status -ne 'Running')) { Start-Sleep -s 5 }", "Write-Output ' -> Waiting for GA Service (WindowsAzureGuestAgent) to start ...'", "while ((Get-Service WindowsAzureGuestAgent).Status -ne 'Running') { Start-Sleep -s 5 }", "Write-Output ' -> Sysprepping VM ...'", "if ( Test-Path $Env:SystemRoot\\system32\\Sysprep\\unattend.xml ) {Remove-Item $Env:SystemRoot\\system32\\Sysprep\\unattend.xml -Force}", "& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /oobe /generalize /quiet /quit", "while ($true) {start-sleep -s 10 ;$imageState = (Get-ItemProperty HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Setup\\State).ImageState; Write-Output $imageState; if ($imageState -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { break }}", "Write-Output ' -> Sysprep complete ...'"]
  }

}
