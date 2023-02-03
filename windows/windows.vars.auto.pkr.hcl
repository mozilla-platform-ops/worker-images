variable "Project" {
  type    = string
  default = "${env("Project")}"
}

variable "base_image" {
  type    = string
  default = "${env("base_image")}"
}

variable "bootstrapscript" {
  type    = string
  default = "${env("bootstrapscript")}"
}

variable "client_id" {
  type    = string
  default = "${env("client_id")}"
}

variable "client_secret" {
  type    = string
  default = "${env("client_secret")}"
  sensitive = true
}

variable "deploymentId" {
  type    = string
  default = "${env("deploymentId")}"
}

variable "disk_additional_size" {
  type    = string
  default = "${env("disk_additional_size")}"
}

variable "image_offer" {
  type    = string
  default = "${env("image_offer")}"
}

variable "image_publisher" {
  type    = string
  default = "${env("image_publisher")}"
}

variable "image_sku" {
  type    = string
  default = "${env("image_sku")}"
}

variable "location" {
  type    = string
  default = "${env("location")}"
}

variable "managed-by" {
  type    = string
  default = "${env("managed_by")}"
}

variable "managed_image_name" {
  type    = string
  default = "${env("managed_image_name")}"
}

variable "managed_image_resource_group_name" {
  type    = string
  default = "${env("managed_image_resource_group_name")}"
}

variable "managed_image_storage_account_type" {
  type    = string
  default = "${env("managed_image_storage_account_type")}"
}

variable "sourceBranch" {
  type    = string
  default = "${env("sourceBranch")}"
}

variable "sourceOrganisation" {
  type    = string
  default = "${env("sourceOrganisation")}"
}

variable "sourceRepository" {
  type    = string
  default = "${env("sourceRepository")}"
}

variable "subscription_id" {
  type    = string
  default = "${env("subscription_id")}"
}

variable "temp_resource_group_name" {
  type    = string
  default = "${env("temp_resource_group_name")}"
}

variable "tenant_id" {
  type    = string
  default = "${env("tenant_id")}"
}

variable "vm_size" {
  type    = string
  default = "${env("vm_size")}"
}

variable "worker_pool_id" {
  type    = string
  default = "${env("worker_pool_id")}"
}
