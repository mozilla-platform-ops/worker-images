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

variable "taskcluster_ref" {
  type    = string
  default = "${env("TASKCLUSTER_REF")}"
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

source "googlecompute" "gw-fxci-gcp-l1-2404-gui-alpha" {
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

source "googlecompute" "gw-fxci-gcp-l1-2404-headless-alpha" {
  disk_size               = var.disk_size
  disk_type               = "pd-ssd"
  image_licenses          = ["projects/vm-options/global/licenses/enable-vmx"]
  image_name              = var.image_name
  machine_type            = null
  project_id              = var.project_id
  source_image_family     = var.source_image_family
  ssh_username            = "ubuntu"
  zone                    = var.zone
  use_iap                 = true
  image_guest_os_features = ["GVNIC"]
}

source "googlecompute" "gw-fxci-gcp-l1-2404-arm64-headless-alpha" {
  disk_size = var.disk_size
  #disk_type           = "pd-ssd"
  image_licenses          = ["projects/vm-options/global/licenses/enable-vmx"]
  image_name              = var.image_name
  machine_type            = "t2a-standard-4"
  project_id              = var.project_id
  source_image_family     = var.source_image_family
  ssh_username            = "ubuntu"
  zone                    = var.zone
  use_iap                 = true
  image_guest_os_features = ["GVNIC"]
}

source "googlecompute" "taskcluster" {
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
    "source.googlecompute.taskcluster",
    "source.googlecompute.gw-fxci-gcp-l1-2404-gui-alpha",
    "source.googlecompute.gw-fxci-gcp-l1-2404-headless-alpha",
    "source.googlecompute.gw-fxci-gcp-l1-2404-arm64-headless-alpha"
  ]

  ## all
  provisioner "shell" {
    execute_command   = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect = true
    scripts = [
      "${path.cwd}/scripts/linux/common/papertrail.sh"
    ]
  }

  ## 2404-headless-alpha & 2404-gui-alpha & 2404-arm64-headless-alpha
  provisioner "shell" {
    only = [
      "source.googlecompute.gw-fxci-gcp-l1-2404-headless-alpha",
      "source.googlecompute.gw-fxci-gcp-l1-2404-gui-alpha",
      "source.googlecompute.gw-fxci-gcp-l1-2404-arm64-headless-alpha"
    ]
    execute_command = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "mkdir -p /workerimages/tests",
      "chmod -R 777 /workerimages/tests",
    ]
  }

  ## 2404-headless-alpha & 2404-gui-alpha & 2404-arm64-headless-alpha
  provisioner "file" {
    only = [
      "source.googlecompute.gw-fxci-gcp-l1-2404-headless-alpha",
      "source.googlecompute.gw-fxci-gcp-l1-2404-gui-alpha",
      "source.googlecompute.gw-fxci-gcp-l1-2404-arm64-headless-alpha"
    ]
    source      = "${path.cwd}/tests/linux/taskcluster.tests.ps1"
    destination = "/workerimages/tests/taskcluster.tests.ps1"
  }

  ## 2404-gui-alpha
  provisioner "shell" {
    only            = ["source.googlecompute.gw-fxci-gcp-l1-2404-gui-alpha"]
    execute_command = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    environment_vars = [
      "CLOUD=google",
      "TC_ARCH=${var.tc_arch}",
      "TASKCLUSTER_VERSION=${var.taskcluster_version}",
      "NUM_LOOPBACK_AUDIO_DEVICES=8",
      "NUM_LOOPBACK_VIDEO_DEVICES=8"
    ]
    expect_disconnect = true
    scripts = [
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-gui/fxci/bootstrap.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-gui/fxci/additional-packages.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-gui/fxci/wayland.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-gui/fxci/pipewire.sh",
      "${path.cwd}/scripts/linux/common/v4l2loopback.sh",
      "${path.cwd}/scripts/linux/common/userns.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-gui/fxci/additional-talos-reqs.sh"
    ]
  }

  ## 2404-gui-alpha
  provisioner "shell" {
    only                = ["source.googlecompute.gw-fxci-gcp-l1-2404-gui-alpha"]
    execute_command     = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect   = true
    pause_before        = "10s"
    start_retry_timeout = "30m"
    scripts = [
      "${path.cwd}/scripts/linux/common/reboot.sh"
    ]
  }

  ## 2404-gui-alpha
  provisioner "shell" {
    only   = ["source.googlecompute.gw-fxci-gcp-l1-2404-gui-alpha"]
    inline = ["/usr/bin/cloud-init status --wait"]
  }

  ## 2404-headless-alpha & 2404-arm64-headless-alpha
  provisioner "shell" {
    only = [
      "source.googlecompute.gw-fxci-gcp-l1-2404-headless-alpha",
      "source.googlecompute.gw-fxci-gcp-l1-2404-arm64-headless-alpha"
    ]
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    environment_vars = [
      "CLOUD=google",
      "TC_ARCH=${var.tc_arch}",
      "TASKCLUSTER_VERSION=${var.taskcluster_version}",
      "NUM_LOOPBACK_AUDIO_DEVICES=8",
      "NUM_LOOPBACK_VIDEO_DEVICES=8"
    ]
    scripts = [
      "${path.cwd}/scripts/linux/common/bootstrap.sh",
      "${path.cwd}/scripts/linux/common/additional-packages.sh",
      "${path.cwd}/scripts/linux/common/aslr.sh",
      "${path.cwd}/scripts/linux/common/docker-config.sh",
      "${path.cwd}/scripts/linux/common/ephemeral-disks.sh",
      "${path.cwd}/scripts/linux/common/userns.sh",
      "${path.cwd}/scripts/linux/common/v4l2loopback.sh"
    ]
  }

  ## 2404-headless-alpha
  provisioner "shell" {
    only              = ["source.googlecompute.gw-fxci-gcp-l1-2404-headless-alpha"]
    execute_command   = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect = true
    scripts = [
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-headless/fxci/nvidia-gcp-driver-cudnn.sh"
    ]
  }

  ## 2404-headless-alpha & 2404-arm64-headless-alpha
  provisioner "shell" {
    only = [
      "source.googlecompute.gw-fxci-gcp-l1-2404-headless-alpha",
      "source.googlecompute.gw-fxci-gcp-l1-2404-arm64-headless-alpha"
    ]
    execute_command     = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect   = true
    pause_before        = "10s"
    start_retry_timeout = "30m"
    scripts = [
      "${path.cwd}/scripts/linux/common/reboot.sh"
    ]
  }

  ## 2404-headless-alpha
  provisioner "shell" {
    only              = ["source.googlecompute.gw-fxci-gcp-l1-2404-headless-alpha"]
    execute_command   = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect = true
    scripts = [
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-headless/fxci/nvidia-container-toolkit.sh"
    ]
  }

  ## 2404-headless-alpha
  provisioner "shell" {
    only                = ["source.googlecompute.gw-fxci-gcp-l1-2404-headless-alpha"]
    execute_command     = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect   = true
    pause_before        = "10s"
    start_retry_timeout = "30m"
    scripts = [
      "${path.cwd}/scripts/linux/common/reboot.sh"
    ]
  }

  ## all
  provisioner "shell" {
    execute_command   = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect = true
    pause_before      = "10s"
    scripts = [
      "${path.cwd}/scripts/linux/common/clean.sh"
    ]
    start_retry_timeout = "30m"
  }

  post-processor "manifest" {
    output     = "packer-artifacts.json"
    strip_path = true
  }

}