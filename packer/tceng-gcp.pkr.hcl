packer {
  required_plugins {
    googlecompute = {
      version = ">= 1.1.4"
      source  = "github.com/hashicorp/googlecompute"
    }
  }
}

# -----------------------------
# Variables (fed via PKR_VAR_*)
# -----------------------------
variable "config" {
  default = env("PKR_VAR_config")
}

variable "image_name" {
  default = env("PKR_VAR_image_name")
}

variable "disk_size" {
  default = env("PKR_VAR_disk_size")
}

variable "project_id" {
  default = env("PKR_VAR_project_id")
}

variable "taskcluster_version" {
  default = env("PKR_VAR_taskcluster_version")
}

variable "taskcluster_ref" {
  default = env("PKR_VAR_taskcluster_ref")
}

variable "tc_arch" {
  default = env("PKR_VAR_tc_arch")
}

variable "source_image_family" {
  default = env("PKR_VAR_source_image_family")
}

variable "zone" {
  default = env("PKR_VAR_zone")
}

variable "bootstrap_script" {
  default = env("PKR_VAR_bootstrap_script")
}

variable "worker_env_var_key" {
  default   = env("PKR_VAR_worker_env_var_key")
  sensitive = true
}

variable "tc_worker_cert" {
  default   = env("PKR_VAR_tc_worker_cert")
  sensitive = true
}

variable "tc_worker_key" {
  default   = env("PKR_VAR_tc_worker_key")
  sensitive = true
}

# -----------------------------
# Source Definition (GCP)
# -----------------------------
source "googlecompute" "generic-worker-ubuntu-24-04-staging" {
  project_id          = var.project_id
  zone                = var.zone
  source_image_family = var.source_image_family
  image_name          = var.image_name
  ssh_username        = "ubuntu"
  disk_size           = parseint(var.disk_size, 10)
  use_iap             = true

  image_labels = {
    "image-set" = var.config
    "arch"      = lower(var.tc_arch)
    "team"      = "tceng"
  }
}

# -----------------------------
# Build Definition
# -----------------------------
build {
  sources = ["source.googlecompute.generic-worker-ubuntu-24-04-staging"]

  provisioner "file" {
    source      = "${path.root}/../scripts/linux/tceng/${var.bootstrap_script}"
    destination = "/tmp/bootstrap.sh"
  }

  provisioner "shell" {
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    environment_vars = [
      "MY_CLOUD=google",
      "CLOUD=google",
      "IMAGE_SET=${var.config}",
      "REGION=${var.zone}",
      "TASKCLUSTER_VERSION=${var.taskcluster_version}",
      "TASKCLUSTER_REF=${var.taskcluster_ref}",
      "TC_ARCH=${var.tc_arch}"
    ]
    scripts = ["/tmp/bootstrap.sh"]
  }

  post-processor "manifest" {
    output     = "packer-artifacts.json"
    strip_path = true
  }
}