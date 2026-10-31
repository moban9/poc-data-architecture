# GCP POC — automated bring-up (Terraform + Docker Compose)
SHELL := /bin/bash
IP      ?= $(shell cd terraform && terraform output -raw instance_public_ip 2>/dev/null)
REMOTE  ?= /opt/poc

.PHONY: help init plan apply deploy status teardown

help:
	@echo "targets: init plan apply deploy status teardown"

init:
	cd terraform && terraform init

plan:
	cd terraform && terraform plan

apply:
	cd terraform && terraform apply -auto-approve
	@echo "VM up at: $(shell cd terraform && terraform output instance_public_ip)"

deploy:
	@test -n "$(IP)" || (echo "run 'make apply' first (need VM IP)"; exit 1)
	ssh root@$(IP) "mkdir -p $(REMOTE)"
	rsync -az --exclude terraform/.terraform --exclude terraform/terraform.tfvars ./ root@$(IP):$(REMOTE)/
	ssh root@$(IP) "cd $(REMOTE)/compose && docker compose up -d --pull always"
	@echo "stack deployed; check with 'make status'"

status:
	@test -n "$(IP)" || (echo "no VM IP"; exit 1)
	ssh root@$(IP) "cd $(REMOTE)/compose && docker compose ps"

teardown:
	cd terraform && terraform destroy -auto-approve
