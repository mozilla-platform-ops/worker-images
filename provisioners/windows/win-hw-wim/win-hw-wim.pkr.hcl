# =============================================================================
# win-hw-wim.pkr.hcl  —  Standalone Hyper-V bake for a golden Windows HW install.wim
#
# Flow: clone a pristine VM (built from your BYO base VHDX) -> WinRM in ->
#       run the ronin BAKE role -> Sysprep /generalize /shutdown ->
#       (post-build) capture the generalized VHDX to install.wim.
#
# NOT related to worker-images/azure.pkr.hcl. No azure-arm source, no gallery.
# Modeled on the provisioner ORDER of azure.pkr.hcl (bootstrap -> puppet ->
# restart -> sysprep) but with a Hyper-V source and a WIM capture output.
# =============================================================================

packer {
  required_plugins {
    hyperv = {
      source  = "github.com/hashicorp/hyperv"
      version = ">= 1.1.3"
    }
    windows-update = {
      source  = "github.com/rgl/windows-update"
      version = ">= 0.16.0"
    }
  }
}

source "hyperv-vmcx" "nuc" {
  # Clone from the pristine base VM (register-base-vm.ps1 wraps the prepared VHDX).
  clone_from_vm_name = var.source_vm_name

  generation       = 2
  cpus             = var.cpus
  memory           = var.memory_mb
  switch_name      = var.switch_name
  output_directory = var.output_directory
  # Build the working VM (clone + its RAM-sized memory-state file) on the big data
  # disk; the default (C: system temp) is too small for a 32 GB memory file.
  temp_path        = var.temp_path

  # Gen2 UEFI. Secure Boot template must match how the base VHDX was prepared.
  enable_secure_boot   = true
  secure_boot_template = "MicrosoftWindows"

  # WinRM — enabled by the unattend injected into the base VHDX (see
  # scripts/unattend/autounattend.xml + prepare-base-vhdx.ps1).
  communicator   = "winrm"
  winrm_username = var.winrm_username
  winrm_password = var.winrm_password
  winrm_timeout  = "60m"

  # Sysprep in the last provisioner shuts the VM down; let Packer treat that as done.
  shutdown_timeout = "30m"
}

build {
  name    = "win-hw-wim-bake"
  sources = ["source.hyperv-vmcx.nuc"]

  # ---- 1. Windows updates (bake them in, so deploy doesn't fight WU) ----
  provisioner "windows-update" {
    # Keep the storm out of the deploy path: fully patch at bake time.
    search_criteria = "IsInstalled=0"
    filters = [
      "exclude:$_.Title -like '*Preview*'",
      "include:$true",
    ]
  }
  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  # ---- 2. Upload bake scripts ----
  provisioner "file" {
    source      = "${path.root}/scripts/"
    destination = "C:/wim-bake/"
  }

  # ---- 3. Bake: install puppet/git, clone ronin, AppX (provisioned) removal, puppet apply of the BAKE role ----
  provisioner "powershell" {
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
    environment_vars = [
      "RONIN_ORG=${var.ronin_org}",
      "RONIN_REPO=${var.ronin_repo}",
      "RONIN_BRANCH=${var.ronin_branch}",
      "RONIN_HASH=${var.ronin_hash}",
      "BAKE_ROLE=${var.bake_role}",
      "PUPPET_VERSION=${var.puppet_version}",
      "GIT_VERSION=${var.git_version}",
      "OPENVOX_VERSION=${var.openvox_version}",
      "RONIN_EXT_SRC=${var.ronin_ext_src}",
    ]
    scripts = ["${path.root}/scripts/bake-bootstrap.ps1"]
    # puppet apply returns 2 when it applied changes — that is success here.
    valid_exit_codes = [0, 2]
  }

  provisioner "windows-restart" {
    restart_timeout = "30m"
  }

  # ---- 4. Scrub machine-specific state + Sysprep /generalize /shutdown ----
  #        (this powers the VM off; Packer then finalizes the artifact)
  provisioner "powershell" {
    elevated_user     = var.winrm_username
    elevated_password = var.winrm_password
    scripts           = ["${path.root}/scripts/sysprep-generalize.ps1"]
  }

  # ---- 5. Capture the generalized VHDX -> golden WIM (runs on the host) ----
  post-processor "shell-local" {
    inline = [
      "powershell -NoProfile -ExecutionPolicy Bypass -File \"${path.root}/scripts/capture-wim.ps1\" -BuildDir \"${var.output_directory}\" -OutWim \"${var.output_wim}\" -Name \"${var.capture_name}\""
    ]
  }
}
