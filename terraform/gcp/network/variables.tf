variable "region" {
  type        = string
  description = "GCP region for subnets, Cloud Router, and NAT"
}

variable "zone" {
  type        = string
  description = "GCP zone for the unmanaged instance group"
}

variable "vpc_name" {
  type        = string
  default     = "poc-vpc"
  description = "Name of the VPC"
}

variable "vpc_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "CIDR block for the VPC"
}

variable "public_subnet_name" {
  type        = string
  default     = "sn-public"
  description = "Public subnet name"
}

variable "private_subnet_name" {
  type        = string
  default     = "sn-private"
  description = "Private subnet name"
}

variable "proxy_subnet_name" {
  type        = string
  default     = "sn-proxy"
  description = "Proxy-only subnet name (REGIONAL_MANAGED_PROXY)"
}

variable "public_subnet_cidr" {
  type        = string
  default     = "10.0.0.0/24"
  description = "CIDR for the public subnet (egress via Cloud NAT)"
}

variable "private_subnet_cidr" {
  type        = string
  default     = "10.0.1.0/24"
  description = "CIDR for the private subnet (app instances, no public IP)"
}

variable "proxy_subnet_cidr" {
  type        = string
  default     = "10.0.2.0/24"
  description = "CIDR for the proxy-only subnet (REGIONAL_MANAGED_PROXY, reserved)"
}

variable "cert_domain" {
  type        = string
  default     = "onendo.cloud"
  description = "Base domain for the Google-managed SSL certificate. Add DNS A records for grafana/demo/bi/plane.<domain> pointing at the LB IP after apply, or the cert stays PROVISIONING."
}

variable "app_port" {
  type        = number
  default     = 80
  description = "TCP port the reverse proxy (Traefik) listens on — IG named port, health check, backend."
}

variable "lb_ingress_ports" {
  type        = list(string)
  default     = ["80", "443"]
  description = "TCP ports the load balancer may reach the app on"
}

variable "app_tag" {
  type        = string
  default     = "app"
  description = "Network tag on app instances, referenced by the firewall rules"
}

variable "lb_source_ranges" {
  type        = list(string)
  default     = ["35.191.0.0/16", "130.211.0.0/22"]
  description = "GCP external HTTP(S) LB proxy + health-check source ranges"
}

variable "iap_ssh_ranges" {
  type        = list(string)
  default     = ["35.235.240.0/20"]
  description = "Identity-Aware Proxy (IAP) TCP forwarding source ranges for SSH"
}

variable "enable_cloud_armor" {
  type        = bool
  default     = true
  description = "Attach a Cloud Armor security policy (default allow) to the backend service"
}

variable "instance_self_links" {
  type        = list(string)
  default     = []
  description = "Self-links of app VMs to attach to the unmanaged instance group (passed by the caller)"
}
