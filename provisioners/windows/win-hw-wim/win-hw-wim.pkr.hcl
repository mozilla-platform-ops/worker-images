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

  # WinRM — the HTTP listener + static NAT IP are set up at first logon by
  # scripts/unattend/set-bake-network.ps1 (dropped in by prepare-base-vhdx.ps1).
  # Use NTLM (message-encrypted), NOT Basic-over-HTTP: the NAT link is classified
  # a 'Public' network, and WinRM refuses to enable AllowUnencrypted there (the
  # firewall-exception guard blocks it), so Basic/plaintext auth can't be turned
  # on. NTLM needs no AllowUnencrypted and works with the local build account.
  communicator   = "winrm"
  winrm_username = var.winrm_username
  winrm_password = var.winrm_password
  winrm_use_ntlm = true
  winrm_timeout  = "60m"

  # Sysprep in the last provisioner shuts the VM down; let Packer treat that as done.
  shutdown_timeout = "30m"
}

build {
  name    = "win-hw-wim-bake"
  sources = ["source.hyperv-vmcx.nuc"]

  # ---- 1. Windows updates (bake them in, so deploy doesn't fight WU) ----
  # Controlled by var.windows_update (per-image config; default OFF for fast
  # iteration, ON for production). Packer HCL can't conditionally include a
  # provisioner, so when disabled we search already-installed updates and exclude
  # everything -> the provisioner finds nothing to install and returns in seconds.
  provisioner "windows-update" {
    # Enabled: latest applicable, not-yet-installed, non-Preview KBs (single pass).
    # Disabled: a no-op search that installs nothing.
    search_criteria = var.windows_update ? "IsInstalled=0" : "IsInstalled=1"
    filters = var.windows_update ? [
      "exclude:$_.Title -like '*Preview*'",
      "include:$true",
    ] : ["exclude:$true"]
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
      # Build-scoped GitHub token for puppet's tooltool download (ronin fact
      # custom_win_github_pat falls back to this env var when there is no D: secrets
      # drive). Empty is fine — tooltool.py is public and the download works without a
      # token. Never written to disk / not captured into the WIM.
      "custom_win_github_pat=${var.github_pat}",
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
