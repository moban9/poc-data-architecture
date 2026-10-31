terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

# Auth: GOOGLE_APPLICATION_CREDENTIALS points at the service-account JSON key
# (Compute Admin + Service Usage Admin), or use `gcloud auth application-default login`.
provider "google" {
  project = var.project_id
  region  = var.region
}

# Ubuntu 22.04 LTS boot image
data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2204-lts"
  project = "ubuntu-os-cloud"
}

# The single POC node — full stack per 05 §9 (8 vCPU / 16 GB / 100 GB)
resource "google_compute_instance" "poc" {
  name         = "${var.name}-vm"
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = data.google_compute_image.ubuntu.self_link
      size  = var.boot_disk_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    network = "default"
    access_config {} # ephemeral public IP
  }

  # Installs Docker + Compose on first boot (idempotent); stack itself is
  # started by `make deploy` so the compose dir can be synced first.
  metadata_startup_script = file("${path.module}/../../scripts/bootstrap.sh")

  tags = [var.name]

  service_account {
    scopes = ["cloud-platform"]
  }
}

resource "google_compute_firewall" "ssh" {
  name    = "${var.name}-ssh"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.allowed_ssh_cidrs
  target_tags   = [var.name]
}

output "instance_public_ip" {
  description = "SSH target and where the stack is served"
  value       = google_compute_instance.poc.network_interface[0].access_config[0].nat_ip
}
