# GCP POC — Automated Setup (IaC) + Live Demo

Reproducible bring-up of the full data-pipeline POC from
`Data Pipeline POC/05 - Data Architecture (Authoritative)`:
one GCP VM → Docker → the complete stack, all as code. Includes a **demo control
panel** (pick a scenario, watch the pipeline react), **real-time Grafana metrics**,
a **visual pipeline-status view**, and **automated incident ticketing** (Plane).

## Layout
```
terraform/    GCP VM (e2-standard-8), boot disk, SSH firewall, Docker bootstrap
compose/      docker-compose.yml (main stack) + monitoring.yml (obs + ticketing)
monitoring/   prometheus + alert rules, alertmanager, ticket-bridge, grafana dashboards
demo/         control panel — FastAPI harness + static UI (animated pipeline view)
dbt/          dbt project — models, tests (schema.yml), quarantine DDL, dirty-data seed
scripts/      bootstrap.sh, incident-simulator.py
Makefile      init / plan / apply / deploy / status / teardown
```

## Docs
- **[Manual setup runbook](docs/00-index.md)** — step-by-step operator guide, in
  bring-up order, written by the team that built each part (infra → stack → pipeline
  → BI → monitoring → demo). Start here if you are standing this up by hand.
- [Architecture & diagrams](docs/architecture.md) — Mermaid (full stack, data flow, network)
- [Examples](docs/examples.md) — bring-up, scenario runs, incident simulation, cost

## Architecture

One VM runs everything; a global external HTTPS load balancer terminates TLS
(managed cert) and forwards to Traefik on the VM, which routes by hostname to each
service. Data path:

```
LMS Postgres ──WAL/pgoutput──▶ Debezium (Kafka Connect)
    ├─▶ Kafka topic lms.public.loan / .loan_event / .borrower   (Bronze, raw events)
    └─▶ Iceberg sink ──▶ Polaris catalog ──▶ S3-compatible object store (warehouse)
                                   │
                        Trino (catalog: lakehouse)
                                   │
                    dbt: stg_* → dim_* → Silver loan/loan_event
                         └─▶ Gold marts (loan_portfolio_summary, loan_event_daily,
                                        loan_delinquency) → Metabase
                         └─▶ quarantine_loan_* (failed dbt tests, kept visible)
```

Prometheus scrapes JMX/lag/Postgres/node exporters and dbt-pushed metrics; alert
rules route through Alertmanager to `ticket-bridge`, which opens a Plane issue.

Full diagrams: [docs/architecture.md](docs/architecture.md). Step-by-step:
[docs/00-index.md](docs/00-index.md).

## Cost (1-day demo ≈ $7)
`e2-standard-8` (8 vCPU/32 GB) $0.268/hr + 100 GB pd-balanced $4/mo. A 1-day run is
~2–3% of the $300 free-trial credit. Trial caps Compute Engine at 8 cores concurrent
(our VM is exactly 8); delete (not stop) after the run — disk bills while stopped.

## Bring-up (one node, ~5 min)
```bash
cd terraform/gcp && cp terraform.tfvars.example terraform.tfvars  # set project_id + cert_domain, tighten SSH
terraform init && terraform plan && terraform apply -auto-approve
cd ../.. && make deploy && make status
```

Or follow the [manual setup runbook](docs/00-index.md) for the same steps with the
verification and failure modes spelled out.

## What comes up
- **Main stack** (`compose/docker-compose.yml`): LMS Postgres + LMS API · S3-compatible
  storage (`adobe/s3mock`) · Polaris · Kafka KRaft · Kafka Connect (Debezium + Iceberg
  sink) · Trino · dbt (one-shot container) · Metabase.
- **Monitoring + ticketing** (`compose/monitoring.yml`): Prometheus · Alertmanager ·
  Grafana · ticket-bridge · **Plane** (open-source Jira-like) · Pushgateway.

## Demo control panel (`https://demo.<cert_domain>`)
FastAPI harness + a self-contained static page. Four scenarios, each runs against the
real pipeline and streams per-hop results; the page shows an **animated SVG pipeline**
(LMS → CDC → Bronze → Silver → Gold → BI) with live per-hop status colors.
- **Inject dirty data** → bad rows trip dbt tests → quarantined (visible, not absorbed).
- **Run healthy CDC flow** → per-hop latency → "queryable in Gold: YES".
- **Simulate pipeline failure** → connector paused → alert → incident ticket auto-opened.
- **Trigger incident ticket** → manual governance-loop demo → ticket id + URL.

## Monitoring & incident management
- Grafana dashboard `pipeline.json` (auto-provisioned): the pipeline topology as a
  vertical chain of **stat panels** that render UP/DOWN as green/red status dots
  (never `1`/`0`), plus time-series for consumer lag, quarantine count, and dbt test
  results.
- Alert rules: `KafkaConnectConnectorFailed`, `KafkaConsumerLagTooHigh`,
  `DbtTestFailures`, `QuarantineRowsPresent`, `ServiceDown`.
- Alert path: Prometheus rule → Alertmanager webhook → `ticket-bridge` → Plane issue
  (`[INCIDENT] <type>: <msg>`, priority urgent). `scripts/incident-simulator.py` emits
  byte-identical tickets for offline demos.

## dbt (tests + quarantine)
`dbt/` is a runnable project: `schema.yml` (not_null, unique, relationships,
positive_value, accepted_values), `macros/` (positive_value, valid_date,
quarantine_insert), `models/quarantine.sql` (lakehouse.quarantine_lms DDL), and
`seeds/dirty_data.csv` (5 rows, each tripping one rule). `dbt test --select dirty_data`
yields exactly 5 failures.

## Security notes (POC posture — tighten for anything longer than a day)
- `allowed_ssh_cidrs` defaults to `0.0.0.0/0`; set it to your IP before apply.
- All default passwords are placeholders — copy `compose/.env.example` → `.env` and
  change every one before a real run.
- Secrets are parameterized via env (`.env`, 0600); never committed.

## Teardown
```bash
make teardown   # terraform destroy (deletes VM + disk + firewall)
```

---

Produced by: Nimbus (infra), Keel (platform), Meridian + Cask (data), Prism (BI),
Relay (observability), Piston (app + demo) · Reviewed by: Ledger
