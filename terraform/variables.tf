variable "project_id" {
  description = "GCP project ID the coordination server is deployed into."
  type        = string
}

variable "region" {
  description = <<-EOT
    GCP region for the VPC/subnet. Defaults to us-central1 because GCP's
    Always Free tier only covers Compute Engine usage in us-west1,
    us-central1, or us-east1 — pick a different region and this stops being
    free.
  EOT
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for the VM. Must be in the region above."
  type        = string
  default     = "us-central1-a"
}

variable "instance_name" {
  description = "Name of the Compute Engine instance."
  type        = string
  default     = "coordination-server"
}

variable "machine_type" {
  description = <<-EOT
    Compute Engine machine type. Defaults to e2-micro — the only shape
    covered by the Always Free tier (1 instance per billing account, not per
    project). e2-small/e2-medium are always billed; use those instead if
    you'd rather have real headroom than a free instance.
  EOT
  type        = string
  default     = "e2-micro"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size in GB. Free tier covers up to 30 GB of pd-standard."
  type        = number
  default     = 30
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
