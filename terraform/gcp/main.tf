terraform {
  required_version = ">= 1.5"

  # Remote state. Every GitHub Actions run is a fresh runner, so state MUST live
  # outside the workspace — with local-only state `terraform apply` re-creates
  # existing resources and fails with 409 "resource already exists".
  #
  # Bucket poc-tf-state-955f419f: asia-southeast2, versioning ON (state history),
  # uniform bucket-level access, public access prevention.
  # Existing local state can be adopted with `terraform init -migrate-state`.
  backend "gcs" {
    bucket = "poc-tf-state-955f419f"
    prefix = "terraform/gcp"
  }

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

# VPC, subnets, NAT, firewalls, Cloud Armor, unmanaged IG, and the external HTTPS LB.
module "network" {
  source = "./network"

  region   = var.region
  zone     = var.zone
  vpc_name = var.vpc_name

  cert_domain = var.cert_domain

  vpc_cidr            = var.vpc_cidr
  public_subnet_cidr  = var.public_subnet_cidr
  private_subnet_cidr = var.private_subnet_cidr
  proxy_subnet_cidr   = var.proxy_subnet_cidr

  app_port           = var.app_port
  lb_ingress_ports   = var.lb_ingress_ports
  app_tag            = var.app_tag
  enable_cloud_armor = var.enable_cloud_armor

  # Attach the app VM to the LB's unmanaged instance group.
  instance_self_links = [google_compute_instance.poc.self_link]
}

# The single POC node — private subnet, NO public IP. Reachable only via IAP
# (SSH) and the external HTTPS LB.
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
    subnetwork = module.network.private_subnet_self_link
    access_config {
      # Ephemeral public IP — used ONLY for the deploy SSH step (firewall-restricted).
      # App traffic still flows through the LB; this IP is not the app endpoint.
    }
  }

  # Installs Docker + Compose on first boot (idempotent); the stack itself is
  # started by `make deploy` so the compose dir can be synced first.
  metadata_startup_script = file("${path.module}/../../scripts/bootstrap.sh")

  # The image is resolved from a live image family, so a routine apply would
  # otherwise see "family moved to a newer build" and REPLACE this running node
  # (terraform treats boot_disk.initialize_params as create-time only). A
  # re-image must be a deliberate act, never a side effect of `terraform apply`.
  lifecycle {
    ignore_changes = [boot_disk[0].initialize_params[0].image]
  }

  metadata = {
    ssh-keys = "ubuntu:ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIER1MBVNAk8entsOyKJwFHYr/QIBIi90F8gLhM+eIYo4 poc-deploy"
  }

  tags = [var.app_tag]

  service_account {
    scopes = ["cloud-platform"]
  }
}

output "load_balancer_ip" {
  description = "External HTTPS load balancer IP — point the cert domain's A record here"
  value       = module.network.lb_ip_address
}

output "instance_public_ip" {
  description = "Ephemeral public IP of the app VM (deploy SSH only; firewall-restricted)"
  value       = google_compute_instance.poc.network_interface[0].access_config[0].nat_ip
}

output "instance_private_ip" {
  description = "Private IP of the app VM (SSH via IAP: gcloud compute ssh --tunnel-through-iap)"
  value       = google_compute_instance.poc.network_interface[0].network_ip
}
