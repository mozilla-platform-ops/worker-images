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

source "googlecompute" "gw-fxci-gcp-l1" {
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

source "googlecompute" "ubuntu2204gw" {
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
  sources = [
    "source.googlecompute.gw-fxci-gcp-l1",
    "source.googlecompute.ubuntu2204gw"
  ]

  ## Every image has tests, so create the tests directory
  provisioner "shell" {
    execute_command = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "mkdir -p /workerimages/tests",
      "chmod -R 777 /workerimages/tests",
    ]
  }

  ## Every image has taskcluster, so upload the taskcluster tests fle
  provisioner "file" {
    source      = "${path.cwd}/tests/linux/taskcluster.tests.ps1"
    destination = "/workerimages/tests/taskcluster.tests.ps1"
  }

  ## Do we need these secrets?
  // provisioner "shell" {
  //   execute_command = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
  //   inline = [
  //     "mkdir -p /etc/taskcluster/secrets",
  //     "touch /etc/taskcluster/secrets/worker_env_var_key",
  //     "touch /etc/taskcluster/secrets/worker_livelog_tls_cert",
  //     "touch /etc/taskcluster/secrets/worker_livelog_tls_key",
  //     "chmod +x /etc/taskcluster/secrets/worker_env_var_key",
  //     "chmod +x /etc/taskcluster/secrets/worker_livelog_tls_cert",
  //     "chmod +x /etc/taskcluster/secrets/worker_livelog_tls_key",
  //   ]
  // }

  provisioner "shell" {
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    only = ["source.googlecompute.ubuntu2404gw"]
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
    only = ["source.googlecompute.gw-fxci-gcp-l1"]
    environment_vars = [
      "CLOUD=google",
      "TC_ARCH=${var.tc_arch}",
      "TASKCLUSTER_VERSION=${var.taskcluster_version}",
    ]
    scripts = [
      "${path.cwd}/scripts/linux/ubuntu-jammy-from-community/05-install.sh",
      "${path.cwd}/scripts/linux/ubuntu-jammy-from-community/10-additional-packages.sh",
      "${path.cwd}/scripts/linux/ubuntu-jammy-from-community/15-additional-pips.sh",
      "${path.cwd}/scripts/linux/ubuntu-jammy-from-community/20-snap-sudo.sh",
      "${path.cwd}/scripts/linux/ubuntu-jammy-from-community/25-hg.sh"
    ]
  }

  # Do we need these secrets?
  // provisioner "shell" {
  //   execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
  //   environment_vars = [
  //     "WORKER_ENV_VAR_KEY=${var.worker_env_var_key}",
  //     "TC_WORKER_CERT=${var.tc_worker_cert}",
  //     "TC_WORKER_KEY=${var.tc_worker_key}"
  //   ]
  //   scripts = [
  //     "${path.cwd}/scripts/linux/taskcluster/tc.sh"
  //   ]
  // }

  # Do we need these secrets?
  // provisioner "shell" {
  //   execute_command = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
  //   inline = [
  //     "chown root:root -R /etc/taskcluster",
  //     "chmod 0400 -R /etc/taskcluster/secrets"
  //   ]
  // }

  provisioner "shell" {
    inline = ["/usr/bin/cloud-init status --wait"]
  }

  ## Install dependencies for tests
  provisioner "shell" {
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    scripts = [
      "${path.cwd}/tests/linux/01_prep.sh",
      "${path.cwd}/tests/linux/02_install_pester.sh"
    ]
  }

  ## Run all tests
  provisioner "shell" {
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    scripts = [
      "${path.cwd}/tests/linux/run_all_tests.sh"
    ]
  }

  ## Install gcp ops agent and cleanup
  provisioner "shell" {
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    scripts = [
      "${path.cwd}/scripts/linux/common/01-install-ops-agent.sh",
      "${path.cwd}/scripts/linux/common/99-clean.sh",
    ]
    start_retry_timeout = "30m"
  }

  post-processor "manifest" {
    output     = "packer-artifacts.json"
    strip_path = true
  }
}
