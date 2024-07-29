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
  default = "${env("DISK_SIZE")}"
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
  type    = string
  default = "${env("ACCESS_TOKEN")}"
  sensitive = true
}

variable "worker_env_var_key" {
  type    = string
  default = "${env("WORKER_ENV_VAR_KEY")}"
  sensitive = true
}

variable "tc_worker_cert" {
  type    = string
  default = "${env("TC_WORKER_CERT")}"
  sensitive = true
}

variable "tc_worker_key" {
  type    = string
  default = "${env("TC_WORKER_KEY")}"
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
  access_token        = var.access_token
}

build {
  sources = ["source.googlecompute.ubuntu2204"]

  ## Upload cloud-init items & helper functions
  provisioner "file" {
    destination = "/etc/"
    source      = "${path.cwd}/files/"
  }

  provisioner "shell" {
    execute_command     = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    environment_vars    = [
      "WORKER_ENV_VAR_KEY=${var.worker_env_var_key}",
      "TC_WORKER_CERT=${var.tc_worker_cert}",
      "TC_WORKER_KEY=${var.tc_worker_key}",
      "CLOUD=google"
    ]
    inline = [
      "sudo mkdir -p /etc/taskcluster/secrets",  
      "echo $WORKER_ENV_VAR_KEY > /etc/taskcluster/secrets/worker_env_var_key",
      "echo $TC_WORKER_CERT > /etc/taskcluster/secrets/worker_livelog_tls_cert",
      "echo $TC_WORKER_KEY > /etc/taskcluster/secrets/worker_livelog_tls_key",
      "sudo chown root:root -R /etc/taskcluster", 
      "sudo chmod 0400 -R /etc/taskcluster/secrets"
    ]
  }

  provisioner "shell" {
    execute_command     = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "sudo mkdir -p /etc/taskcluster/secrets",  
      "sudo chown root:root -R /etc/taskcluster", 
      "sudo chmod 0400 -R /etc/taskcluster/secrets"
    ]
  }

  provisioner "shell" {
    inline = ["/usr/bin/cloud-init status --wait"]
  }

  ## Run OS specific scripts
  provisioner "shell" {
    only = ["source.googlecompute.ubuntu2204"]
    execute_command     = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    scripts = [
      "scripts/ubuntu-tc-barebones/01-install-packages.sh",
    ]
  }

  ## Install taskcluster binaries
  provisioner "shell" {
    environment_vars    = [
      "TASKCLUSTER_VERSION=${var.taskcluster_version}",
      "TC_ARCH=${var.tc_arch}",
      "CLOUD=google"
    ]
    execute_command     = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect   = true
    scripts             = [
      "scripts/linux/ubuntu-tc-barebones/05-install-tc.sh",
      ]
    start_retry_timeout = "30m"
  }

  ## Clean up prior to creating the image
  provisioner "shell" {
    execute_command     = "sudo -S sh -c '{{ .Vars }} {{ .Path }}'"
    expect_disconnect   = true
    inline             = ["apt-get autoremove -y --purge"]
    start_retry_timeout = "30m"
  }

  post-processor "manifest" {
    output     = "packer-artifacts.json"
    strip_path = true
  }
}
