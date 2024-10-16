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

source "googlecompute" "gw-fxci-gcp-l1-2404-alpha" {
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

source "googlecompute" "gw-fxci-gcp-l1-2404-gui" {
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

source "googlecompute" "gw-fxci-gcp-l1-arm64" {
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

source "googlecompute" "gw-fxci-gcp-l1-arm64-gui" {
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

source "googlecompute" "gw-fxci-gcp-l1-2404-tc" {
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

source "googlecompute" "gw-fxci-gcp-l1-2404-x11-alpha" {
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
    "source.googlecompute.gw-fxci-gcp-l1-2404-alpha"
  ]
  
  // ## Every image has tests, so create the tests directory
  // provisioner "shell" {
  //   execute_command = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
  //   inline = [
  //     "mkdir -p /workerimages/tests",
  //     "chmod -R 777 /workerimages/tests",
  //   ]
  // }

  // ## Every image has taskcluster, so upload the taskcluster tests fle
  // provisioner "file" {
  //   source      = "${path.cwd}/tests/linux/taskcluster.tests.ps1"
  //   destination = "/workerimages/tests/taskcluster.tests.ps1"
  // }

  provisioner "shell" {
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    environment_vars = [
      "CLOUD=google",
      "TC_ARCH=${var.tc_arch}",
      "TASKCLUSTER_VERSION=${var.taskcluster_version}",
    ]
    scripts = [
      "${path.cwd}/scripts/linux/common/papertrail.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64/fxci/01-bootstrap.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64/fxci/02-additional-packages.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64/fxci/03-hg.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64/fxci/04-aslr.sh",
    ]
  }

  provisioner "shell" {
    inline = ["/usr/bin/cloud-init status --wait"]
  }

  ## Install dependencies for tests
  // provisioner "shell" {
  //   execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
  //   scripts = [
  //     "${path.cwd}/tests/linux/01_prep.sh",
  //     "${path.cwd}/tests/linux/02_install_pester.sh"
  //   ]
  // }

  // ## Run all tests
  // provisioner "shell" {
  //   execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
  //   scripts = [
  //     "${path.cwd}/tests/linux/run_all_tests.sh"
  //   ]
  // }

  ## Install gcp ops agent and cleanup
  provisioner "shell" {
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect = true
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

build {
  sources = [
    "source.googlecompute.gw-fxci-gcp-l1-2404-gui"
  ]

  ## Let's use taskcluster community shell script, the staging version
  provisioner "shell" {
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
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-gui/fxci/01-bootstrap.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-gui/fxci/02-additional-packages.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-gui/fxci/04-wayland.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-gui/fxci/99-additional-talos-reqs.sh"
    ]
  }

  ## Reboot to get wayland config applied
  provisioner "shell" {
    execute_command = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect = true
    pause_before = "10s"
    start_retry_timeout = "30m"
    scripts = [
      "${path.cwd}/scripts/linux/common/reboot.sh"
    ]
  }

  provisioner "shell" {
    inline = ["/usr/bin/cloud-init status --wait"]
  }

  ## Install gcp ops agent and cleanup
  provisioner "shell" {
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect = true
    pause_before = "10s"
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

build {
  sources = [
    "source.googlecompute.gw-fxci-gcp-l1-2404-gui-alpha"
  ]
  
  // ## Every image has tests, so create the tests directory
  // provisioner "shell" {
  //   execute_command = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
  //   inline = [
  //     "mkdir -p /workerimages/tests",
  //     "chmod -R 777 /workerimages/tests",
  //   ]
  // }

  // ## Every image has taskcluster, so upload the taskcluster tests fle
  // provisioner "file" {
  //   source      = "${path.cwd}/tests/linux/taskcluster.tests.ps1"
  //   destination = "/workerimages/tests/taskcluster.tests.ps1"
  // }

  ## Let's use taskcluster community shell script, the staging version
  provisioner "shell" {
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
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-gui/fxci/01-bootstrap.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-gui/fxci/02-additional-packages.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-gui/fxci/04-wayland.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-gui/fxci/99-additional-talos-reqs.sh"
    ]
  }

  ## Reboot to get wayland config applied
  provisioner "shell" {
    execute_command = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect = true
    pause_before = "10s"
    start_retry_timeout = "30m"
    scripts = [
      "${path.cwd}/scripts/linux/common/reboot.sh"
    ]
  }

  provisioner "shell" {
    inline = ["/usr/bin/cloud-init status --wait"]
  }

  // ## Install dependencies for tests
  // provisioner "shell" {
  //   execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
  //   scripts = [
  //     "${path.cwd}/tests/linux/01_prep.sh",
  //     "${path.cwd}/tests/linux/02_install_pester.sh"
  //   ]
  // }

  // ## Run all tests
  // provisioner "shell" {
  //   execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
  //   scripts = [
  //     "${path.cwd}/tests/linux/run_all_tests.sh"
  //   ]
  // }

  ## Install gcp ops agent and cleanup
  provisioner "shell" {
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect = true
    pause_before = "10s"
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

build {
  sources = [
    "source.googlecompute.gw-fxci-gcp-l1-2404-tc"
  ]

  ## Let's use taskcluster community shell script, the staging version
  provisioner "shell" {
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect = true
    scripts = [
      "${path.cwd}/scripts/linux/tc-ubuntu-2404-amd64-staging/bootstrap.sh",
    ]
  }

  post-processor "manifest" {
    output     = "packer-artifacts.json"
    strip_path = true
  }

}

build {
  sources = [
    "source.googlecompute.gw-fxci-gcp-l1-2404-x11-alpha"
  ]

  provisioner "shell" {
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    environment_vars = [
      "CLOUD=google",
      "TC_ARCH=${var.tc_arch}",
      "TASKCLUSTER_VERSION=${var.taskcluster_version}",
    ]
    scripts = [
      "${path.cwd}/scripts/linux/common/papertrail.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-x11/fxci/01-bootstrap.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-x11/fxci/02-additional-packages.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-x11/fxci/03-x11.sh"
    ]
  }

  provisioner "shell" {
    inline = ["/usr/bin/cloud-init status --wait"]
  }

  ## Install gcp ops agent and cleanup
  provisioner "shell" {
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect = true
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

build {
  sources = [
    "source.googlecompute.gw-fxci-gcp-l1-2404-headless-alpha"
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

  provisioner "shell" {
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    environment_vars = [
      "CLOUD=google",
      "TC_ARCH=${var.tc_arch}",
      "TASKCLUSTER_VERSION=${var.taskcluster_version}",
    ]
    scripts = [
      "${path.cwd}/scripts/linux/common/papertrail.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-headless/fxci/01-bootstrap.sh",
      "${path.cwd}/scripts/linux/ubuntu-2404-amd64-headless/fxci/02-additional-packages.sh"
    ]
  }

  provisioner "shell" {
    inline = ["/usr/bin/cloud-init status --wait"]
  }

  ## Install gcp ops agent and cleanup
  provisioner "shell" {
    execute_command = "sudo -S bash -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect = true
    scripts = [
      "${path.cwd}/scripts/linux/common/01-install-ops-agent.sh",
      "${path.cwd}/scripts/linux/common/99-clean.sh",
    ]
    start_retry_timeout = "30m"
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
      "${path.cwd}/tests/linux/run_all_tests.sh"
    ]
  }

  post-processor "manifest" {
    output     = "packer-artifacts.json"
    strip_path = true
  }

}