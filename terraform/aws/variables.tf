variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  type    = string
  default = "lms-poc"
}

variable "instance_type" {
  type        = string
  default     = "m7i.2xlarge" # 8 vCPU / 32 GB
  description = "m7i.2xlarge (8/32) or m7i.large for a smaller dev box"
}

variable "boot_disk_gb" {
  type    = number
  default = 100
}

variable "key_name" {
  type        = string
  description = "Existing EC2 key pair name (create in console → Key Pairs)"
}

variable "allowed_ssh_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "SSH source ranges — tighten to your own IP for anything longer than a day"
}
