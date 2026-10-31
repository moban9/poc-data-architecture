# POC — automated bring-up (Terraform + Docker Compose), multi-cloud.
#   make PROVIDER=aws apply   → spin up on AWS
#   make PROVIDER=gcp apply   → spin up on GCP
SHELL := /bin/bash
PROVIDER ?= gcp
TF_DIR  := terraform/gcp
ifeq ($(PROVIDER),aws)
TF_DIR := terraform/aws
endif
IP     ?= $(shell cd $(TF_DIR) && terraform output -raw instance_public_ip 2>/dev/null)
REMOTE ?= /opt/poc

.PHONY: help init plan apply deploy virtualize status teardown

help:
	@echo "PROVIDER=$(PROVIDER) (aws|gcp) — targets: init plan apply deploy virtualize status teardown"

init:
	cd $(TF_DIR) && terraform init

plan:
	cd $(TF_DIR) && terraform plan

apply:
	cd $(TF_DIR) && terraform apply -auto-approve
	@echo "VM up at: $(shell cd $(TF_DIR) && terraform output instance_public_ip)"

deploy:
	@test -n "$(IP)" || (echo "run 'make apply' first (need VM IP)"; exit 1)
	ssh root@$(IP) "mkdir -p $(REMOTE)"
	rsync -az --exclude terraform --exclude .git ./ root@$(IP):$(REMOTE)/
	ssh root@$(IP) "cd $(REMOTE)/compose && docker compose up -d --pull always"
	@echo "deployed — check with 'make status'"

# Data-virtualization demo: same query, two engines, one catalog (pending lake wiring).
virtualize:
	@test -n "$(IP)" || (echo "run 'make apply' first"; exit 1)
	@echo "=== Trino ==="
	ssh root@$(IP) "cd $(REMOTE)/compose && docker compose exec trino trino --file /demo/virtualization.sql"
	@echo "=== DuckDB ==="
	ssh root@$(IP) "cd $(REMOTE)/compose && docker compose run --rm duckdb -c '.read /demo/virtualization.sql'"

status:
	@test -n "$(IP)" || (echo "no VM IP"; exit 1)
	ssh root@$(IP) "cd $(REMOTE)/compose && docker compose ps"

teardown:
	cd $(TF_DIR) && terraform destroy -auto-approve
