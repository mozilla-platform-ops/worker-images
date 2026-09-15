packer {
  required_plugins {
    googlecompute = {
      source  = "github.com/hashicorp/googlecompute"
      version = "= 1.2.4"
    }
  }
}

data "googlecompute-secretsmanager" "cot" {
  project_id = var.project_id
  name       = "cot"
}

local "cotkey" {
  expression = var.use_keyvault ? data.googlecompute-secretsmanager.cot.payload : ""
  sensitive  = true
}

variable "image_name" {
  type    = string
  default = "${env("IMAGE_NAME")}"
}

variable "use_keyvault" {
  type        = bool
  default     = false
  description = "Whether to fetch secrets from Google Secrets Manager"
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

variable "machine_type" {
  type    = string
  default = "e2-standard-8"
}

source "googlecompute" "gw-fxci-gcp-l1-2404-gui-alpha" {
  disk_size           = var.disk_size
  disk_type           = "pd-ssd"
  image_licenses      = ["projects/vm-options/global/licenses/enable-vmx"]
  image_name          = var.image_name
  machine_type        = var.machine_type
  project_id          = var.project_id
  source_image_family = var.source_image_family
  ssh_username        = "ubuntu"
  zone                = var.zone
  use_iap             = true
}

source "googlecompute" "trusted-gw-fxci-gcp-l3-2404-headless-alpha" {
  disk_size               = var.disk_size
  disk_type               = "pd-ssd"
  image_licenses          = ["projects/vm-options/global/licenses/enable-vmx"]
  image_name              = var.image_name
  machine_type            = var.machine_type
  project_id              = var.project_id
  source_image_family     = var.source_image_family
  ssh_username            = "ubuntu"
  zone                    = var.zone
  use_iap                 = true
  image_guest_os_features = ["GVNIC"]
}

source "googlecompute" "gw-fxci-gcp-l1-2404-headless-alpha" {
  disk_size               = var.disk_size
  disk_type               = "pd-ssd"
  image_licenses          = ["projects/vm-options/global/licenses/enable-vmx"]
  image_name              = var.image_name
  machine_type            = var.machine_type
  project_id              = var.project_id
  source_image_family     = var.source_image_family
  ssh_username            = "ubuntu"
  zone                    = var.zone
  use_iap                 = true
  image_guest_os_features = ["GVNIC"]
}

source "googlecompute" "gw-fxci-gcp-l1-2404-arm64-headless-alpha" {
  disk_size               = var.disk_size
  disk_type               = "pd-ssd"
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

source "googlecompute" "trusted-gw-fxci-gcp-l3-2404-arm64-headless-alpha" {
  disk_size               = var.disk_size
  disk_type               = "pd-ssd"
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

build {
  sources = [
    "source.googlecompute.gw-fxci-gcp-l1-2404-headless-alpha",
    "source.googlecompute.gw-fxci-gcp-l1-2404-gui-alpha",
    "source.googlecompute.gw-fxci-gcp-l1-2404-arm64-headless-alpha",
    "source.googlecompute.trusted-gw-fxci-gcp-l3-2404-headless-alpha",
    "source.googlecompute.trusted-gw-fxci-gcp-l3-2404-arm64-headless-alpha"
  ]

  provisioner "shell" {
    only = [
      "googlecompute.gw-fxci-gcp-l1-2404-gui-alpha"
    ]
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
      "${path.cwd}/scripts/linux/common/papertrail.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-gui/fxci/bootstrap.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-gui/fxci/additional-packages.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-gui/fxci/wayland.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-gui/fxci/pipewire.sh",
      "${path.cwd}/scripts/linux/common/v4l2loopback.sh",
      "${path.cwd}/scripts/linux/common/userns.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-gui/fxci/additional-talos-reqs.sh"
    ]
  }

  provisioner "shell" {
    except = [
      "googlecompute.gw-fxci-gcp-l1-2404-gui-alpha"
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
      "${path.cwd}/scripts/linux/common/papertrail.sh",
      "${path.cwd}/scripts/linux/common/bootstrap.sh",
      "${path.cwd}/scripts/linux/common/additional-packages.sh",
      "${path.cwd}/scripts/linux/common/aslr.sh",
      "${path.cwd}/scripts/linux/common/docker-config.sh",
      "${path.cwd}/scripts/linux/common/ephemeral-disks.sh",
      "${path.cwd}/scripts/linux/common/userns.sh",
      "${path.cwd}/scripts/linux/common/v4l2loopback.sh"
    ]
  }

  provisioner "shell" {
    only = [
      "googlecompute.gw-fxci-gcp-l1-2404-headless-alpha"
    ]
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    scripts = [
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-headless/fxci/podman.sh"
    ]
  }

  provisioner "shell" {
    only = [
      "googlecompute.gw-fxci-gcp-l1-2404-headless-alpha"
    ]
    execute_command   = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect = true
    environment_vars = [
      "CLOUD=google",
      "TC_ARCH=${var.tc_arch}",
      "TASKCLUSTER_VERSION=${var.taskcluster_version}",
      "NUM_LOOPBACK_AUDIO_DEVICES=8",
      "NUM_LOOPBACK_VIDEO_DEVICES=8"
    ]
    scripts = [
      "${path.cwd}/scripts/linux/common/configure-nvidia-gpus.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-headless/fxci/nvidia-gcp-driver-cudnn.sh"
    ]
  }

  provisioner "shell" {
    only = [
      "googlecompute.gw-fxci-gcp-l1-2404-headless-alpha",
      "googlecompute.gw-fxci-gcp-l1-2404-arm64-headless-alpha"
    ]
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    scripts = [
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-headless/fxci/nvidia-container-toolkit.sh"
    ]
  }

  # Reboot once, after all package and container-runtime changes.
  provisioner "shell" {
    execute_command     = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect   = true
    pause_before        = "0s"
    pause_after         = "30s"
    start_retry_timeout = "30m"
    scripts = [
      "${path.cwd}/scripts/linux/common/reboot.sh"
    ]
  }

  provisioner "shell" {
    only = [
      "googlecompute.trusted-gw-fxci-gcp-l3-2404-headless-alpha",
      "googlecompute.trusted-gw-fxci-gcp-l3-2404-arm64-headless-alpha"
    ]
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    environment_vars = [
      "cotkey=${local.cotkey}",
      "use_keyvault=${var.use_keyvault}"
    ]
    scripts = [
      "${path.cwd}/scripts/linux/common/cot.sh"
    ]
    valid_exit_codes = [
      0
    ]
  }

  provisioner "shell" {
    only            = ["googlecompute.gw-fxci-gcp-l1-2404-headless-alpha"]
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    script          = "${path.cwd}/tests/linux/test_nvidia.sh"
  }

  ## Run all tests
  provisioner "shell" {
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    environment_vars = [
      "CLOUD=google",
      "TC_ARCH=${var.tc_arch}",
      "TASKCLUSTER_VERSION=${var.taskcluster_version}",
    ]
    scripts = [
      "${path.cwd}/tests/linux/test_taskcluster.sh",
      "${path.cwd}/tests/linux/test_docker.sh"
    ]
    valid_exit_codes = [
      0
    ]
  }

  provisioner "shell" {
    execute_command   = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect = true
    scripts = [
      "${path.cwd}/scripts/linux/common/clean.sh",
    ]
    start_retry_timeout = "30m"
  }

  provisioner "file" {
    source      = "${path.cwd}/scripts/linux/common/generate-sbom.sh"
    destination = "/tmp/generate-linux-sbom.sh"
  }

  provisioner "shell" {
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    environment_vars = [
      "IMAGE_NAME=${var.image_name}",
      "TASKCLUSTER_VERSION=${var.taskcluster_version}",
      "TASKCLUSTER_REF=${var.taskcluster_ref}",
      "TC_ARCH=${var.tc_arch}",
      "SOURCE_IMAGE_FAMILY=${var.source_image_family}",
      "PROJECT_ID=${var.project_id}",
      "ZONE=${var.zone}"
    ]
    inline = [
      "bash /tmp/generate-linux-sbom.sh",
      "rm -f /tmp/generate-linux-sbom.sh"
    ]
  }

  provisioner "file" {
    destination = "${path.cwd}/sboms/${var.image_name}.md"
    direction   = "download"
    max_retries = 3
    source      = "/etc/worker-images/SBOM.md"
  }

  post-processor "manifest" {
    output     = "packer-artifacts.json"
    strip_path = true
  }

}
