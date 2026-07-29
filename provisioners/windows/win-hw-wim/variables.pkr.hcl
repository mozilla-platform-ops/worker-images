# Input variables for the Windows HW baked-WIM Packer build.
# Copy example.auto.pkrvars.hcl to <name>.auto.pkrvars.hcl and set values.

variable "source_vm_name" {
  type        = string
  description = "Name of the pristine Gen2 Hyper-V VM built around the base VHDX (created by register-base-vm.ps1). Packer clones from this VM so it stays untouched."
}

variable "switch_name" {
  type        = string
  description = "Hyper-V virtual switch the build VM attaches to (must reach the internet for Puppet/choco)."
}

variable "winrm_username" {
  type        = string
  default     = "packer"
  description = "Local admin account created by the injected unattend for Packer WinRM."
}

variable "winrm_password" {
  type        = string
  sensitive   = true
  description = "Password for the build-only WinRM account (build-scoped; not baked into the final image)."
}

variable "github_pat" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Build-scoped GitHub token for puppet's tooltool download (exposed to the bake as env custom_win_github_pat). Empty is OK — tooltool.py is public. Not baked into the WIM."
}

variable "windows_update" {
  type        = bool
  default     = false
  description = "Run a full online Windows Update pass during the bake. Default OFF (fast iteration); production images set this true via config. See the windows-update provisioner in win-hw-wim.pkr.hcl."
}

variable "cpus" {
  type    = number
  default = 4
}

variable "memory_mb" {
  type    = number
  default = 8192
}

# --- ronin bake inputs (passed to bake-bootstrap.ps1) ---

variable "ronin_org" {
  type    = string
  default = "mozilla-platform-ops"
}

variable "ronin_repo" {
  type    = string
  default = "ronin_puppet"
}

variable "ronin_branch" {
  type        = string
  description = "Branch carrying the win116424h2hwbake role (feature branch; do not use main until merged)."
}

variable "ronin_hash" {
  type        = string
  default     = ""
  description = "Optional pinned commit to checkout after clone. Empty = branch HEAD."
}

variable "bake_role" {
  type    = string
  default = "win116424h2hwbake"
}

variable "puppet_version" {
  type = string
}

variable "git_version" {
  type = string
}

variable "openvox_version" {
  type    = string
  default = ""
}

# Ronin's public assets blob that hosts the pinned prerequisite installers under
# /binaries/prerequisites (e.g. openvox-agent-<ver>-x64.msi, puppet-agent-<ver>-x64.msi).
# Same source Get-PreRequ uses in worker-images MDC1Windows/bootstrap.ps1.
variable "ronin_ext_src" {
  type    = string
  default = "https://roninpuppetassets.blob.core.windows.net/binaries/prerequisites"
}

variable "output_directory" {
  type        = string
  default     = "./output/build"
  description = "Where Packer writes the cloned VM + generalized VHDX."
}

variable "temp_path" {
  type        = string
  default     = ""
  description = "Where the hyperv builder creates the working VM (clone + its RAM-sized memory-state file). Must be on a disk large enough for the VHDX clone + the VM's memory file (= memory_mb). Set to the big data disk; empty = system temp (C:, too small)."
}

variable "output_wim" {
  type        = string
  default     = "./output/install.wim"
  description = "Path the capture post-processor writes the golden WIM to. Set per-image by the orchestrator (e.g. work/<image>/<image>-<buildid>.wim) so parallel/repeat builds never collide."
}

variable "capture_name" {
  type        = string
  default     = "nuc-ci-baked"
  description = "DISM /Name metadata written into the captured image."
}
