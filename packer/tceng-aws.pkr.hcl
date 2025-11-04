packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.2"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

# -----------------------------
# Variables (fed via PKR_VAR_*)
# -----------------------------
variable "config" { default = env("PKR_VAR_config") }
variable "ami_name" { default = env("PKR_VAR_ami_name") }
variable "disk_size" { default = env("PKR_VAR_disk_size") }
variable "region" { default = env("PKR_VAR_region") }
variable "taskcluster_version" { default = env("PKR_VAR_taskcluster_version") }
variable "taskcluster_ref" { default = env("PKR_VAR_taskcluster_ref") }
variable "tc_arch" { default = env("PKR_VAR_tc_arch") }
variable "source_ami" { default = env("PKR_VAR_source_ami") }
variable "source_ami_owner" { default = env("PKR_VAR_source_ami_owner") }
variable "source_ami_filter" { default = env("PKR_VAR_source_ami_filter") }
variable "instance_type" { default = env("PKR_VAR_instance_type") }
variable "bootstrap_script" { default = env("PKR_VAR_bootstrap_script") }
variable "ami_regions" {
  type    = list(string)
  default = []
}

variable "iam_instance_profile" {
  type    = string
  default = env("PKR_VAR_iam_instance_profile")
}

# NEW: assume_role for GitHub OIDC authentication
variable "assume_role_arn" {
  type    = string
  default = env("PKR_VAR_assume_role_arn")
}

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

# -----------------------------
# Source Definition (AWS)
# -----------------------------
source "amazon-ebs" "tceng" {
  # Authentication - uses assume_role for GitHub OIDC
  assume_role {
    role_arn     = var.assume_role_arn
    session_name = "packer-tceng-build"
  }

  region        = var.region
  instance_type = var.instance_type != "" ? var.instance_type : null
  ami_name      = var.ami_name
  ami_regions   = var.ami_regions

  # Source AMI
  source_ami_filter {
    filters = {
      name                = var.source_ami_filter
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = [var.source_ami_owner]
  }

  # SSH communicator
  ssh_username = "ubuntu"

  # IAM instance profile (if needed for build-time permissions)
  iam_instance_profile = var.iam_instance_profile != "" ? var.iam_instance_profile : null

  # Storage
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = local.disk_size_int
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # Tags
  tags = {
    "image-set" = var.config
    "arch"      = local.arch_label
    "team"      = "tceng"
  }

  # Snapshot tags
  snapshot_tags = {
    "image-set" = var.config
    "arch"      = local.arch_label
    "team"      = "tceng"
  }
}

# -----------------------------
# Build Definition
# -----------------------------
build {
  name    = "tceng"
  sources = ["source.amazon-ebs.tceng"]

  provisioner "shell" {
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    environment_vars = [
      "MY_CLOUD=aws",
      "IMAGE_SET=${var.config}",
      "REGION=${var.region}",
      "TASKCLUSTER_VERSION=${var.taskcluster_version}",
      "TASKCLUSTER_REF=${var.taskcluster_ref}",
      "TC_ARCH=${var.tc_arch}"
    ]
    script = "${path.cwd}/scripts/linux/tceng/${var.bootstrap_script}"
  }

  post-processor "manifest" {
    output     = "packer-artifacts.json"
    strip_path = true
  }
}
