variable "project_id" {
  type        = string
  description = "GCP project ID (billing/free-trial active)"
}

variable "name" {
  type        = string
  default     = "lms-poc"
  description = "Prefix for the VM and firewall rule"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

variable "machine_type" {
  type        = string
  default     = "e2-standard-8" # 8 vCPU / 32 GB — cheapest 8-core, wide availability (POC-minimized)
  description = "e2-standard-8 (8 vCPU/32GB) or e2-standard-4 (4 vCPU/16GB — tight for the full stack)"
}

variable "boot_disk_gb" {
  type    = number
  default = 100
}

variable "allowed_ssh_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "SSH source ranges — tighten to your own IP for anything longer than a day"
}
