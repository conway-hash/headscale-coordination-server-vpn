output "external_ip" {
  description = "Static external IP — point your domain's DNS A record here."
  value       = google_compute_address.static_ip.address
}

output "instance_name" {
  description = "Compute Engine instance name (used as the Ansible/IAP tunnel target)."
  value       = google_compute_instance.coordination_server.name
}

output "zone" {
  description = "Zone the instance runs in (needed for the IAP tunnel)."
  value       = var.zone
}
