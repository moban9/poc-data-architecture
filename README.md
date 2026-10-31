# GCP POC — Automated Setup (IaC)

Reproducible bring-up of the full data pipeline POC from
`Data Pipeline POC/05 - Data Architecture (Authoritative)`:
one GCP VM → Docker → the complete stack, all as code.

## Layout
```
terraform/   GCP VM (n2-standard-8), boot disk, SSH firewall, Docker bootstrap
compose/     docker-compose.yml — every stack component, heaps pinned to 05 §9
scripts/     bootstrap.sh — idempotent Docker + Compose install (also cloud-init)
Makefile     init / plan / apply / deploy / status / teardown
```

## Prerequisites
1. GCP project with billing (free-trial $300/90-day credit) active.
2. A service-account JSON key with **Compute Admin + Service Usage Admin**.
3. `terraform`, `docker`, and `rsync` on the machine you run this from.

## Bring-up (one node, ~5 min)
```bash
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json

cd terraform
cp terraform.tfvars.example terraform.tfvars   # set project_id, tighten SSH CIDR
terraform init
terraform plan
terraform apply -auto-approve                  # VM up; Docker installed on boot

cd ..
make deploy                                     # rsync repo → VM, docker compose up -d
make status                                     # all services healthy
```

## What comes up (compose)
LMS Postgres + LMS API · MinIO · Polaris (+ Postgres) · Kafka KRaft · Kafka
Connect (Debezium + Iceberg sink) · Trino · Dagster (+ in-process dbt) ·
Metabase · Prometheus · Grafana · node-exporter.

## Security notes (POC posture, tighten for anything longer than a day)
- `allowed_ssh_cidrs` defaults to `0.0.0.0/0` — set it to your IP before apply.
- All default passwords in `compose/.env.example` are placeholders — copy to
  `compose/.env` and change every one before a real run.
- The service-account key is not committed; `terraform.tfvars` is gitignored.

## Owned TODOs (in compose, by owner)
| Owner | Work |
|---|---|
| Piston | `src/lms` FastAPI + deterministic seed (02) |
| Cask | Debezium source + Iceberg sink connector JAR/configs; register-connectors.sh |
| Meridian | trino catalogs, polaris properties, dbt project |
| Relay | JMX exporters, Grafana dashboards, alert rules |

## Teardown
```bash
make teardown   # terraform destroy (deletes the VM + firewall)
```
