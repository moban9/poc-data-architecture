variable "project_id" {
  type        = string
  description = "GCP project ID (billing/free-trial active)"
}

variable "name" {
  type        = string
  default     = "lms-poc"
  description = "Prefix for the VM and other resources"
}

variable "region" {
  type        = string
  default     = "asia-southeast2"
  description = "GCP region for the VPC, subnets, LB, and app VM"
}

variable "zone" {
  type        = string
  default     = "asia-southeast2-a"
  description = "GCP zone for the app VM and unmanaged instance group"
}

variable "machine_type" {
  type        = string
  default     = "e2-standard-8"
  description = "e2-standard-8 (8 vCPU / 32 GB) — cheapest 8-core, wide availability (POC-minimized)"
}

variable "boot_disk_gb" {
  type    = number
  default = 100
}

variable "vpc_name" {
  type        = string
  default     = "poc-vpc"
  description = "VPC name"
}

variable "vpc_cidr" {
  type        = string
  default     = "10.0.0.0/16"
  description = "VPC CIDR block"
}

variable "public_subnet_cidr" {
  type        = string
  default     = "10.0.0.0/24"
  description = "Public subnet CIDR (sn-public, egress via Cloud NAT)"
}

variable "private_subnet_cidr" {
  type        = string
  default     = "10.0.1.0/24"
  description = "Private subnet CIDR (sn-private, app instances)"
}

variable "proxy_subnet_cidr" {
  type        = string
  default     = "10.0.2.0/24"
  description = "Proxy-only subnet CIDR (sn-proxy, REGIONAL_MANAGED_PROXY)"
}

variable "cert_domain" {
  type        = string
  default     = "onendo.cloud"
  description = "Base domain for the Google-managed SSL cert. Add DNS A records for grafana/demo/bi/plane.<domain> pointing at the LB IP after apply, or the cert stays PROVISIONING."
}

variable "app_port" {
  type        = number
  default     = 80
  description = "TCP port the reverse proxy (Traefik) listens on — LB backend, health check, firewall."
}

variable "lb_ingress_ports" {
  type        = list(string)
  default     = ["80", "443"]
  description = "TCP ports the load balancer may reach the app on"
}

variable "app_tag" {
  type        = string
  default     = "app"
  description = "Network tag applied to the VM and used by the firewall rules"
}

variable "enable_cloud_armor" {
  type        = bool
  default     = true
  description = "Attach a Cloud Armor security policy (default allow) to the LB backend"
}
