packer {
  required_plugins {
    googlecompute = {
      version = ">= 1.1.4"
      source  = "github.com/hashicorp/googlecompute"
    }
  }
}

# ---------- Variables ----------
variable "config"              { default = env("PKR_VAR_config") }
variable "image_name"          { default = env("PKR_VAR_image_name") }
variable "project_id"          { default = env("PKR_VAR_project_id") }
variable "zone"                { default = env("PKR_VAR_zone") }
variable "source_image_family" { default = env("PKR_VAR_source_image_family") }
variable "disk_size"           { default = env("PKR_VAR_disk_size") }
variable "tc_arch"             { default = env("PKR_VAR_tc_arch") }
variable "taskcluster_version" { default = env("PKR_VAR_taskcluster_version") }
variable "taskcluster_ref"     { default = env("PKR_VAR_taskcluster_ref") }
variable "bootstrap_script"    { default = env("PKR_VAR_bootstrap_script") }
variable "team_key"            { default = env("PKR_VAR_Team_key") }

variable "worker_env_var_key" {
  type      = string
  default   = env("PKR_VAR_worker_env_var_key")
  sensitive = true
}
variable "tc_worker_cert" {
  type      = string
  default   = env("PKR_VAR_tc_worker_cert")
  sensitive = true
}
variable "tc_worker_key" {
  type      = string
  default   = env("PKR_VAR_tc_worker_key")
  sensitive = true
}

locals {
  disk_size_int = try(parseint(var.disk_size, 10), var.disk_size)
  arch_label    = lower(var.tc_arch)
}

# ---------- Source ----------
source "googlecompute" "tceng" {
  project_id              = var.project_id
  zone                    = var.zone
  source_image_project_id = ["ubuntu-os-cloud"]
  source_image_family     = var.source_image_family
  image_name              = var.image_name
  ssh_username            = "ubuntu"
  disk_size               = local.disk_size_int
  use_iap                 = true

  image_labels = {
    "image-set" = var.config
    "arch"      = local.arch_label
    "team"      = var.team_key
  }
}

# ---------- Build ----------
build {
  name    = "tceng"
  sources = ["source.googlecompute.tceng"]

  # dynamically uses the team path (scripts/linux/<team>/...)
  provisioner "file" {
    source      = "${path.root}/../scripts/linux/${var.team_key}/${var.bootstrap_script}"
    destination = "/tmp/bootstrap.sh"
  }

  provisioner "shell" {
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    environment_vars = [
      "MY_CLOUD=google",
      "IMAGE_SET=${var.config}",
      "REGION=${var.zone}",
      "TASKCLUSTER_VERSION=${var.taskcluster_version}",
      "TASKCLUSTER_REF=${var.taskcluster_ref}",
      "TC_ARCH=${var.tc_arch}",
      "WORKER_ENV_VAR_KEY=${var.worker_env_var_key}",
      "TC_WORKER_CERT=${var.tc_worker_cert}",
      "TC_WORKER_KEY=${var.tc_worker_key}"
    ]
    script = "/tmp/bootstrap.sh"
  }

  post-processor "manifest" {
    output     = "packer-artifacts.json"
    strip_path = true
  }
}