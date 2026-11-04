# Manual Setup — Operator Runbook (start here)

Step-by-step manual bring-up of the whole POC, written by the team that built each
part and checked against the repo files (not from memory). Follow it top to bottom,
once, on a clean GCP project. Expect most of the wall-clock time to be spent waiting:
`terraform apply`, image pulls, and the managed certificate.

If you only want the fast path, the `Makefile` (see [README](../README.md)) encodes
the same sequence. Use this runbook when a step fails, or when you need to
understand what each command actually creates.

## Order (and why)

| # | Doc | Covers | Produces | Owner |
|---|-----|--------|----------|-------|
| 1 | [GCP infrastructure](01-gcp-infra.md) | Project, APIs, WIF, network, VM, load balancer, managed cert, GitHub Actions | A reachable VM + HTTPS edge | Nimbus |
| 2 | [Docker Compose + Traefik](02-docker-compose.md) | `.env`, bring-up order, service inventory, routing, volumes, restart policy | The running stack behind Traefik | Keel |
| 3 | [Data pipeline](03-data-pipeline.md) | MinIO bucket, Polaris catalog, Kafka topics, Debezium, Iceberg sink, Trino, dbt | Bronze → Silver → Gold, queryable in Trino | Meridian + Cask |
| 4 | [Metabase](04-metabase.md) | Trino connection, first-run admin, dashboard cards | BI layer over Gold | Prism |
| 5 | [Monitoring](05-monitoring.md) | Prometheus jobs, alerts, Alertmanager → Plane tickets, Grafana, reboot recovery | Observability + ticketing loop | Relay |
| 6 | [LMS + demo panel](06-lms-demo.md) | LMS schema/API, seeding, demo scenarios | The demo story you show people | Piston |

Reference material, already in the repo: [architecture.md](architecture.md) (Mermaid
diagrams of stack, data flow, network) and [examples.md](examples.md) (worked examples
and cost).

When bronze stops filling — sink `RUNNING` but `committed to 0 table(s)`, or Polaris
401 `Failed to verify token` after a restart — work through
[the Bronze CDC runbook](07-cdc-bronze-runbook.md). It also carries the only
supported verification: inject N loans, watch the bronze count move by N.

## Before you start — you need

- A GCP project with billing enabled and the free-trial credit intact (the VM is
  exactly 8 vCPU, which is the trial's concurrent-core cap).
- `gcloud` authenticated as a project owner, `terraform` ≥ 1.5, `docker` + compose v2
  on the VM (the startup script installs it), and the `gcloud compute ssh` path that
  the workflows expect (`ubuntu` user).
- DNS control for the domain you use. All hostnames are `<name>.<DOMAIN>` with
  `DOMAIN` defaulting to `onendo.cloud` (`compose/traefik/dynamic.yml`); the managed
  certificate is issued for 12 SANs, so **all of them must resolve before the cert
  leaves `PROVISIONING`**.
- Nothing else. No secrets are committed; every credential comes from `.env`, and
  `.env.example` lists every variable with a placeholder.

## What you should be able to reach when done

| URL | Service | Port behind it |
|-----|---------|----------------|
| `https://lms.<DOMAIN>` | LMS API (FastAPI) | `8000` |
| `https://demo.<DOMAIN>` | Demo control panel | `8000` (internal only) |
| `https://trino.<DOMAIN>` | Trino UI / SQL | `8080` |
| `https://polaris.<DOMAIN>` | Polaris catalog | `8181` |
| `https://minio.<DOMAIN>` | S3 API (`adobe/s3mock`; no web console) | `9000` |
| `https://connect.<DOMAIN>` | Kafka Connect REST | `8083` |
| `https://bi.<DOMAIN>` | Metabase | `3000` (published on `8085`) |
| `https://grafana.<DOMAIN>` | Grafana | `3000` |
| `https://prometheus.<DOMAIN>` | Prometheus | `9090` |
| `https://alertmanager.<DOMAIN>` | Alertmanager | `9093` |
| `https://pushgateway.<DOMAIN>` | Pushgateway | `9091` |
| `https://plane.<DOMAIN>` | Plane (ticketing) | `3010` / `3011` |

Also published on the VM but *not* behind Traefik: `5432` (LMS Postgres), `5433`
(Polaris Postgres), `9092` (Kafka), `9000` (S3 mock), `8000` (LMS API), `8085`
(Metabase), `8001` (**ticket-bridge**, not the demo panel), `8010` (Plane API),
`3010` (Plane web), `3011` (Plane admin), `9090`, `9091`, `9093`, `9100`, `9115`,
`9187`, `9190`. (`7071`–`7074` are the JMX javaagent ports, container-internal only — not published to the host; Prometheus scrapes them over the docker network.)

## Verification rhythm

Each doc ends with its own checks. The rule: **do not move to the next document
until the previous one's verification section passes.** The single most common
wasted hour in this stack is debugging dbt when the real fault is an unregistered
Debezium connector two layers down.

## Known gaps in the repo (documented, not papered over)

These are real inconsistencies found while writing these docs; each is called out at
the relevant step. None block a demo bring-up.

- `compose/.env.example` defines `DAGSTER_IMAGE` / `DAGSTER_PG_PASSWORD`, and the
  demo panel probes `DAGSTER_URL`. A `dagster` service now exists
  (`compose/docker-compose.yml` → `dagster` + `dagster-daemon` + `dagster-postgres`,
  built from `dagster/Dockerfile`) and owns the dbt run via
  `dbt_pipeline_schedule`; the one-shot `dbt` service and the VM cron are kept
  until the schedule is verified in the UI, then retired.
- `Makefile`'s `deploy` target does not pass `--env-file monitoring.env`, so
  monitoring-only variables are not applied on that path.
- `compose/trino/catalog/README.md` mentions a `bucket-setup` service that does not
  exist; bucket creation actually happens in `compose/polaris/init-lakehouse.sh`.
- `README.md` and `docs/examples.md` used to say the demo panel is on `:8001`; that
  port is the ticket-bridge. The panel is served through Traefik at `demo.<DOMAIN>`
  (see [06](06-lms-demo.md#3-the-demo-control-panel-demo)). Fixed in the README.

---

Produced by: Nimbus, Keel, Meridian, Cask, Prism, Relay, Piston · Reviewed by: Ledger
