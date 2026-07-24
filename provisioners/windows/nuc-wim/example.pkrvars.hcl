# REFERENCE ONLY for a manual `packer build -var-file=...` run.
# Normal builds go through bin/NucWim/New-NucWim.ps1, which reads config/<image>.yaml
# and generates work/<image>/build.pkrvars.hcl for you — you don't edit this file.
# Do NOT commit real values (.gitignore ignores *.pkrvars.hcl except this example).

source_vm_name = "nuc-wim-base"                # created by register-base-vm.ps1
switch_name    = "Default Switch"              # or your external switch with internet

winrm_username = "packer"
winrm_password = "CHANGE-ME-build-only"        # build-scoped; scrubbed before capture

cpus      = 4
memory_mb = 8192

# ronin bake source — use the FEATURE branch carrying win116424h2hwbake (not main)
ronin_org    = "mozilla-platform-ops"
ronin_repo   = "ronin_puppet"
ronin_branch = "wim-bake-role"
ronin_hash   = ""                              # optional pinned commit
bake_role    = "win116424h2hwbake"

# Pinned to worker-images config/windows_production_defaults.yaml (source of truth).
# openvox_version is set, so Get-PreRequ installs openvox-agent-<ver>-x64.msi and
# ignores puppet_version for the installer (kept for reference/parity).
puppet_version  = "8.10.0"
git_version     = "2.54.0"
openvox_version = "8.24.2"

output_directory = "./output/build"
