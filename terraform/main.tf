resource "google_compute_network" "vpc" {
  name                    = "${var.instance_name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = "10.10.0.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
}

resource "google_compute_address" "static_ip" {
  name   = "${var.instance_name}-ip"
  region = var.region
}

# Caddy needs 80/443 reachable from the internet: 80 for ACME HTTP-01
# challenges, 443 for the actual proxied traffic.
resource "google_compute_firewall" "allow_web" {
  name          = "${var.instance_name}-allow-web"
  network       = google_compute_network.vpc.id
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["coordination-server"]

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
}

# SSH is reachable ONLY through Identity-Aware Proxy's tunnel range — never
# directly from the public internet. GitHub Actions authenticates as the
# deployer service account and opens the tunnel with `gcloud compute
# start-iap-tunnel`; see .github/workflows/deploy.yml.
resource "google_compute_firewall" "allow_iap_ssh" {
  name          = "${var.instance_name}-allow-iap-ssh"
  network       = google_compute_network.vpc.id
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["coordination-server"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_instance" "coordination_server" {
  name         = var.instance_name
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["coordination-server"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = var.boot_disk_size_gb
      # pd-standard, not pd-balanced/pd-ssd — only pd-standard is covered by
      # the Always Free tier (up to 30 GB).
      type = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    access_config {
      nat_ip = google_compute_address.static_ip.address
    }
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  # No service account attached — the containers on this box never call a
  # GCP API, so it has zero standing access to anything, by construction
  # rather than by narrowly-scoped IAM. (This also keeps the deployer SA's
  # own permissions smaller: it never needs to create service accounts or
  # edit project IAM policy.)

  metadata = {
    ssh-keys = "${var.ssh_user}:${var.ssh_public_key}"
  }
}
