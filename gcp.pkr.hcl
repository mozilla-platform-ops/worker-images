packer {
  required_plugins {
    googlecompute = {
      version = ">= 1.1.4"
      source  = "github.com/hashicorp/googlecompute"
    }
  }
}

variable "image_name" {
  type    = string
  default = "${env("IMAGE_NAME")}"
}

variable "disk_size" {
  type    = number
  default = 100
}

variable "project_id" {
  type    = string
  default = "${env("PROJECT_ID")}"
}

variable "taskcluster_version" {
  type    = string
  default = "${env("TASKCLUSTER_VERSION")}"
}

variable "tc_arch" {
  type    = string
  default = "${env("TC_ARCH")}"
}

variable "source_image_family" {
  type    = string
  default = "${env("SOURCE_IMAGE_FAMILY")}"
}

variable "zone" {
  type    = string
  default = "${env("ZONE")}"
}

variable "access_token" {
  type      = string
  default   = "${env("ACCESS_TOKEN")}"
  sensitive = true
}

variable "worker_env_var_key" {
  type      = string
  default   = "${env("WORKER_ENV_VAR_KEY")}"
  sensitive = true
}

variable "tc_worker_cert" {
  type      = string
  default   = "${env("TC_WORKER_CERT")}"
  sensitive = true
}

variable "tc_worker_key" {
  type      = string
  default   = "${env("TC_WORKER_KEY")}"
  sensitive = true
}

source "googlecompute" "ubuntu2204" {
  disk_size           = var.disk_size
  image_licenses      = ["projects/vm-options/global/licenses/enable-vmx"]
  image_name          = var.image_name
  machine_type        = null
  project_id          = var.project_id
  source_image_family = var.source_image_family
  ssh_username        = "ubuntu"
  zone                = var.zone
  use_iap             = true
}

build {
  sources = ["source.googlecompute.ubuntu2204"]

  provisioner "shell" {
    execute_command = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "mkdir -p /workerimages/tests"
    ]
  }

  ## Just start with taskcluster tests using pester
  provisioner "file" {
    source      = "${path.cwd}/tests/linux/taskcluster.tests.ps1"
    destination = "/workerimages/tests/taskcluster.tests.ps1"
  }

  provisioner "shell" {
    execute_command = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "mkdir -p /etc/taskcluster/secrets",
      "touch /etc/taskcluster/secrets/worker_env_var_key",
      "touch /etc/taskcluster/secrets/worker_livelog_tls_cert",
      "touch /etc/taskcluster/secrets/worker_livelog_tls_key",
      "chmod +x /etc/taskcluster/secrets/worker_env_var_key",
      "chmod +x /etc/taskcluster/secrets/worker_livelog_tls_cert",
      "chmod +x /etc/taskcluster/secrets/worker_livelog_tls_key",
    ]
  }

  provisioner "shell" {
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    environment_vars = [
      "CLOUD=google",
      "TC_ARCH=${var.tc_arch}",
      "TASKCLUSTER_VERSION=${var.taskcluster_version}",
    ]
    scripts = [
      "${path.cwd}/scripts/linux/ubuntu-community-2404-bootstrap/bootstrap.sh"
    ]
  }

  provisioner "shell" {
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    environment_vars = [
      "WORKER_ENV_VAR_KEY=${var.worker_env_var_key}",
      "TC_WORKER_CERT=${var.tc_worker_cert}",
      "TC_WORKER_KEY=${var.tc_worker_key}"
    ]
    scripts = [
      "${path.cwd}/scripts/linux/taskcluster/tc.sh"
    ]
  }

  provisioner "shell" {
    execute_command = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "chown root:root -R /etc/taskcluster",
      "chmod 0400 -R /etc/taskcluster/secrets"
    ]
  }

  provisioner "shell" {
    inline = ["/usr/bin/cloud-init status --wait"]
  }

  ## Install dependencies for tests
  provisioner "shell" {
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    scripts = [
      "${path.cwd}/tests/linux/01_prep.sh"
    ]
  }

  ## Run all tests
  provisioner "shell" {
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    scripts = [
      "${path.cwd}/tests/linux/run_all_tests.sh"
    ]
  }

  ## Clean up prior to creating the image
  provisioner "shell" {
    execute_command     = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect   = true
    inline              = ["apt-get autoremove -y --purge"]
    start_retry_timeout = "30m"
  }

  post-processor "manifest" {
    output     = "packer-artifacts.json"
    strip_path = true
  }
}
