variable "project_id" {
  description = "GCP project ID the coordination server is deployed into."
  type        = string
}

variable "region" {
  description = "GCP region for the VPC/subnet."
  type        = string
  default     = "europe-west1"
}

variable "zone" {
  description = "GCP zone for the VM."
  type        = string
  default     = "europe-west1-b"
}

variable "instance_name" {
  description = "Name of the Compute Engine instance."
  type        = string
  default     = "coordination-server"
}

variable "machine_type" {
  description = "Compute Engine machine type. e2-small comfortably runs headscale + headplane + caddy at small/personal scale."
  type        = string
  default     = "e2-small"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size in GB."
  type        = number
  default     = 20
}

variable "ssh_user" {
  description = "Linux user Ansible connects as and that owns the metadata SSH key."
  type        = string
  default     = "deploy"
}

variable "ssh_public_key" {
  description = "Public half of the SSH keypair Ansible uses to reach the VM over the IAP tunnel. The private half never touches this repo — it lives only as the SSH_PRIVATE_KEY GitHub secret."
  type        = string
  sensitive   = true
}
