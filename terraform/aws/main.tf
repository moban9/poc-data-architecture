terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Auth: AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (or `aws configure`), scoped IAM user.
provider "aws" {
  region = var.region
}

# Ubuntu 22.04 LTS (Canonical AMI)
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-22.04-amd64-server-*"]
  }
}

resource "aws_security_group" "poc" {
  name        = "${var.name}-sg"
  description = "SSH only (tighten CIDR)"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "poc" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.poc.id]

  root_block_device {
    volume_size = var.boot_disk_gb
    volume_type = "gp3"
  }

  # Installs Docker + Compose on first boot (idempotent); stack started by `make deploy`.
  user_data = file("${path.module}/../../scripts/bootstrap.sh")

  tags = { Name = var.name }
}

output "instance_public_ip" {
  value = aws_instance.poc.public_ip
}
