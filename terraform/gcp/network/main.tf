# ─────────────────────────────────────────────────────────────────────────────
# POC network module
# VPC + subnets (public / private / proxy) + Cloud Router/NAT + firewall
# + Cloud Armor + global external HTTPS LB backed by an unmanaged instance group
# ─────────────────────────────────────────────────────────────────────────────

# VPC — no auto subnetworks; each subnet is declared explicitly below.
resource "google_compute_network" "vpc" {
  name                    = var.vpc_name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

# Public subnet — egress only via Cloud NAT (no instance gets a public IP here).
resource "google_compute_subnetwork" "public" {
  name          = var.public_subnet_name
  network       = google_compute_network.vpc.id
  region        = var.region
  ip_cidr_range = var.public_subnet_cidr
}

# Private subnet — app instances, no public IP.
resource "google_compute_subnetwork" "private" {
  name          = var.private_subnet_name
  network       = google_compute_network.vpc.id
  region        = var.region
  ip_cidr_range = var.private_subnet_cidr
}

# Proxy-only subnet — reserved for a regional Envoy (managed proxy) LB.
# Cannot host VMs. Provisioned ahead of a regional external Application LB.
resource "google_compute_subnetwork" "proxy" {
  name          = var.proxy_subnet_name
  network       = google_compute_network.vpc.id
  region        = var.region
  ip_cidr_range = var.proxy_subnet_cidr
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

# Cloud Router + Cloud NAT — outbound internet for the private subnet.
resource "google_compute_router" "router" {
  name    = "${var.vpc_name}-router"
  network = google_compute_network.vpc.id
  region  = var.region
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.vpc_name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  subnetwork {
    name                    = google_compute_subnetwork.private.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

# ── Firewall ──────────────────────────────────────────────────────────────────

# Allow the external HTTPS LB (proxy + health checks) to reach the app on 80/443.
resource "google_compute_firewall" "allow_lb" {
  name    = "${var.vpc_name}-allow-lb"
  network = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
    ports    = var.lb_ingress_ports
  }

  source_ranges = var.lb_source_ranges
  target_tags   = [var.app_tag]
}

# Allow IAP TCP forwarding for SSH (the VM has no public IP).
resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "${var.vpc_name}-allow-iap-ssh"
  network = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.iap_ssh_ranges
  target_tags   = [var.app_tag]
}

# POC: allow SSH from anywhere so the CI deploy step can reach the VM.
# TIGHTEN to a known CIDR (GitHub runner / your IP) before any production use.
resource "google_compute_firewall" "allow_ssh_public" {
  name    = "${var.vpc_name}-allow-ssh-public"
  network = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = [var.app_tag]
}

# Allow all traffic within the VPC (service-to-service).
resource "google_compute_firewall" "allow_internal" {
  name    = "${var.vpc_name}-allow-internal"
  network = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [var.vpc_cidr]
}

# Default-deny everything else. Lowest precedence (65534) so the allows above win.
resource "google_compute_firewall" "deny_all_ingress" {
  name      = "${var.vpc_name}-deny-all-ingress"
  network   = google_compute_network.vpc.id
  direction = "INGRESS"
  priority  = 65534

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]
}

# ── Cloud Armor (default allow — tune before production) ──────────────────────

resource "google_compute_security_policy" "armor" {
  count = var.enable_cloud_armor ? 1 : 0
  name  = "${var.vpc_name}-armor"

  rule {
    action      = "allow"
    priority    = 2147483647
    description = "Default rule: allow all"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}

# ── Global external HTTPS load balancer ───────────────────────────────────────

# Global static IP for the LB.
resource "google_compute_global_address" "lb_ip" {
  name = "${var.vpc_name}-lb-ip"
}

# Unmanaged instance group holding the app VM(s). Instances are attached by the
# caller (root module) via `instance_self_links` — this keeps the module free of
# a dependency on the app instance (avoids module -> instance -> module cycle).
resource "google_compute_instance_group" "app" {
  name      = "${var.vpc_name}-app-ig"
  zone      = var.zone
  network   = google_compute_network.vpc.self_link
  instances = var.instance_self_links

  named_port {
    name = "https"
    port = var.app_port
  }
}

resource "google_compute_health_check" "app" {
  name = "${var.vpc_name}-health-check"

  tcp_health_check {
    port = var.app_port
  }

  timeout_sec         = 5
  check_interval_sec  = 10
  healthy_threshold   = 2
  unhealthy_threshold = 3
}

resource "google_compute_backend_service" "app" {
  name            = "${var.vpc_name}-backend"
  protocol        = "HTTP"
  health_checks   = [google_compute_health_check.app.id]
  security_policy = one(google_compute_security_policy.armor[*].id)

  backend {
    group = google_compute_instance_group.app.self_link
  }
}

resource "google_compute_url_map" "app" {
  name            = "${var.vpc_name}-url-map"
  default_service = google_compute_backend_service.app.id
}

# Placeholder: cert stays PROVISIONING until DNS points cert_domain at lb_ip.
resource "google_compute_managed_ssl_certificate" "cert" {
  name = "${var.vpc_name}-managed-cert"

  managed {
    domains = [
      "grafana.${var.cert_domain}",
      "demo.${var.cert_domain}",
      "bi.${var.cert_domain}",
      "plane.${var.cert_domain}",
    ]
  }
}

resource "google_compute_target_https_proxy" "proxy" {
  name             = "${var.vpc_name}-https-proxy"
  url_map          = google_compute_url_map.app.id
  ssl_certificates = [google_compute_managed_ssl_certificate.cert.id]
}

resource "google_compute_global_forwarding_rule" "https" {
  name        = "${var.vpc_name}-https-forwarding-rule"
  target      = google_compute_target_https_proxy.proxy.id
  ip_address  = google_compute_global_address.lb_ip.address
  ip_protocol = "TCP"
  port_range  = "443"
}
