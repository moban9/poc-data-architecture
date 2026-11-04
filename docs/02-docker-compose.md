# 02 — Docker Compose + Traefik (Manual Setup)

Operator runbook for bringing up the POC stack on a single VM by hand. Everything
below is grounded in `compose/docker-compose.yml`, `compose/monitoring.yml`,
`compose/traefik.yml`, `compose/.env.example`, `compose/monitoring.env.example`,
the `compose/traefik/`, `compose/plane-admin/`, `compose/connectors/`,
`compose/polaris/`, `compose/trino/` files, and the `Makefile`.

The stack is **three Compose files** that run as separate projects but share one
network:

| File | Project `name:` | Role |
|---|---|---|
| `docker-compose.yml` | `lms-poc` | Main pipeline + declares the shared network `lms-poc` |
| `monitoring.yml` | `lms-monitoring` | Metrics + Plane incident ticketing |
| `traefik.yml` | — (no `name:` set) | Edge reverse proxy |

The shared network is `networks.default.name: lms-poc`, declared only in
`docker-compose.yml`; the monitoring and traefik services attach to `default`
(`networks: [default]`). That is why the base stack must come up first (or all
three files be merged in one invocation, as the Makefile does).

---

## 1. Prerequisites on the VM

- A VM running a Debian-family distro (the `Makefile` deploys to `ubuntu@<IP>`
  at `/home/ubuntu/poc`).
- Docker Engine + the **Compose v2 plugin** (`docker compose`, not
  `docker-compose`).
- SSH reachable for the deploy path (`make deploy` rsyncs the repo over SSH):
  port **22**.
- The **GCP HTTPS Load Balancer** terminates TLS on **443** with a managed
  certificate covering 12 explicit SANs (`grafana`/`demo`/`bi`/`plane`/`trino`/`polaris`/`minio`/`connect`/`lms`/`prometheus`/`alertmanager`/`pushgateway`) and forwards **plain HTTP** to the VM's port
  **80** (Traefik's only entrypoint — see `traefik/traefik.yml`). So the VM needs
  inbound **80**; **443** lives on the LB, not on the VM.
- **DNS records must exist before TLS can issue.** The LB managed cert is **not a
  wildcard** — it is 12 explicit SANs (`terraform/gcp/network/main.tf`):
  `grafana`, `demo`, `bi`, `plane`, `trino`, `polaris`, `minio`, `connect`, `lms`,
  `prometheus`, `alertmanager`, `pushgateway`. **All 12** must resolve to the LB
  IP before GCP will provision the cert (a wildcard `*.onendo.cloud` A record
  does **not** satisfy a multi-SAN managed cert).
- Free resources per the budget in `docker-compose.yml` header: 8 vCPU / 16 GB /
  100 GB disk on one node. Memory is hard-capped per service via `mem_limit`.

---

## 2. `.env` setup

Two env files drive the stack:

- `compose/.env` — auto-loaded (same directory as the Compose files) by both the
  base stack and Traefik. Copy from `compose/.env.example`.
- `compose/monitoring.env` — loaded only when you pass
  `--env-file monitoring.env`. Copy from `compose/monitoring.env.example`.

> Note: the `Makefile` `deploy` target's combined command does **not** pass
> `--env-file monitoring.env`, so in that path the monitoring services fall back
> to the inline defaults in `monitoring.yml` and the `GRAFANA_PASSWORD` value in
> `.env`. To drive Plane/Grafana from env, bring the monitoring overlay up
> explicitly with `--env-file monitoring.env` (see §3).

Generate strong secrets with:

```bash
openssl rand -hex 32        # 64 hex chars, URL-safe
openssl rand -base64 32     # includes +/= — avoid for URL-embedded values
```

### 2a. `compose/.env.example` — every variable

| Variable | Purpose | Safe example / generation |
|---|---|---|
| `LMS_DB_USER` | Source (LMS) Postgres user | `lms` — keep |
| `LMS_DB_PASSWORD` | Source Postgres password (also used by Debezium source + register-connectors) | `openssl rand -hex 16` |
| `LMS_DB_NAME` | Source database name | `lms` — keep |
| `POLARIS_DB_USER` | Polaris metadata Postgres user | `polaris` — keep |
| `POLARIS_DB_PASSWORD` | Polaris metadata Postgres password | `openssl rand -hex 16` |
| `POLARIS_DB_NAME` | Polaris metadata database | `polaris` — keep |
| `MINIO_ROOT_USER` | MinIO (s3mock) root access key (== S3 access key) | `minioadmin` — keep or change |
| `MINIO_ROOT_PASSWORD` | MinIO root secret (== S3 secret key) | `openssl rand -hex 16` |
| `POLARIS_URI` | Trino Iceberg REST catalog endpoint | `http://polaris:8181/api/catalog` — keep |
| `POLARIS_WAREHOUSE` | Polaris catalog name (`lakehouse`) | `lakehouse` — keep |
| `POLARIS_REALM` | Polaris realm | `POLARIS` — keep |
| `POLARIS_CLIENT_ID` | Polaris OAuth2 bootstrap principal id | `root` — keep |
| `POLARIS_CLIENT_SECRET` | Polaris bootstrap client secret. **Must contain no `:`** (embedded as `id:secret`) | `openssl rand -hex 24` |
| `POLARIS_PERSISTENCE_TYPE` | Polaris persistence mode | `relational-jdbc` — keep |
| `MINIO_ENDPOINT` | S3 endpoint (Polaris + Trino + sink + init) | `http://minio:9000` — keep |
| `MINIO_REGION` | S3 region | `us-east-1` — keep |
| `MINIO_ACCESS_KEY` | S3 access key (must match `MINIO_ROOT_USER`) | `minioadmin` — match root user |
| `MINIO_SECRET_KEY` | S3 secret (must match `MINIO_ROOT_PASSWORD`) | match root password |
| `MINIO_BUCKET` | Iceberg base-location bucket | `lakehouse` — keep |
| `DAGSTER_PG_USER` | Dagster instance Postgres user (`dagster-postgres`) | `dagster` — keep |
| `DAGSTER_PG_PASSWORD` | Dagster Postgres password (`dagster-postgres`, used via `dagster.yaml` `{env: ...}`) | `openssl rand -hex 16` |
| `DAGSTER_PG_DB` | Dagster instance database | `dagster` — keep |
| `DAGSTER_HOST_PORT` | Host port for the Dagster UI (**3000 is taken by Grafana**) | `3001` |
| `DAGSTER_DBT_CRON` | Cadence of the dbt pipeline schedule (cron syntax, UTC) | `*/2 * * * *` (old cron parity) |
| `GRAFANA_PASSWORD` | Grafana admin password (used by the `grafana` service in `monitoring.yml`) | `openssl rand -hex 16` |
| `POSTGRES_IMAGE` | Postgres image pin | `postgres:16` — keep |
| `POLARIS_IMAGE` | Polaris image pin | `apache/polaris:latest` |
| `MINIO_IMAGE` | MinIO/s3mock image pin | `adobe/s3mock:latest` |
| `KAFKA_IMAGE` | Kafka image pin | `apache/kafka:3.8.1` |
| `CONNECT_IMAGE` | Kafka Connect image pin | `debezium/connect:2.7.3.Final` |
| `TRINO_IMAGE` | Trino image pin | `trinodb/trino:latest` |
| `DAGSTER_IMAGE` | Dagster image tag (built from `../dagster`, not a registry pull — see `dagster/Dockerfile`) | `onendo-dagster:latest` |
| `METABASE_IMAGE` | Metabase image pin | `metabase/metabase:latest` |
| `PROMETHEUS_IMAGE` | Prometheus image pin | `prom/prometheus:latest` |
| `GRAFANA_IMAGE` | Grafana image pin | `grafana/grafana:latest` |
| `NODE_EXPORTER_IMAGE` | Node exporter image pin | `prom/node-exporter:latest` |
| `DUCKDB_IMAGE` | DuckDB image pin | `duckdb/duckdb:latest` |
| `TRAEFIK_IMAGE` | Traefik image pin | `traefik:v3.2` |
| `DOMAIN` | Base domain for Traefik `Host` rules | `onendo.cloud` |
| `CONNECT_URL` | Kafka Connect REST URL (used by connector templates) | `http://localhost:8083` |
| `LMS_DB_HOST` | Debezium source target host | `lms-postgres` — keep |
| `LMS_DB_PORT` | Debezium source port | `5432` — keep |
| `LMS_TOPIC_PREFIX` | Kafka topic prefix (`lms.public.*`) | `lms` — keep |
| `DBZ_TABLE_INCLUDE_LIST` | Tables Debezium captures | `public.loan,public.loan_event,public.borrower` |
| `DBZ_SLOT_NAME` | Replication slot name | `lms_poc_debezium` |
| `DBZ_PUBLICATION_NAME` | Publication name | `lms_poc_publication` |
| `ICEBERG_CATALOG_URI` | Iceberg sink REST catalog URI | `http://polaris:8181/api/catalog` |
| `ICEBERG_WAREHOUSE` | Polaris catalog name for the sink | `lakehouse` |
| `ICEBERG_TABLES` | Bronze tables the sink creates | `bronze.loan,bronze.loan_event,bronze.borrower` |
| `SINK_TOPICS_REGEX` | Topics the sink consumes | `lms.public.*` |
| `MINIO_PATH_STYLE` | S3 path-style access flag | `true` |
| `POLARIS_CREDENTIAL` | Sink credential `client-id:client-secret` | `root:<POLARIS_CLIENT_SECRET>` |
| `POLARIS_SCOPE` | Sink OAuth scope | `PRINCIPAL_ROLE:ALL` |

(`MINIO_ENDPOINT` and `MINIO_REGION` appear twice in `.env.example`; list them once.)

### 2b. `compose/monitoring.env.example` — every variable

| Variable | Purpose | Safe example / generation |
|---|---|---|
| `GRAFANA_USER` | Grafana admin username | `admin` |
| `GRAFANA_PASSWORD` | Grafana admin password | `openssl rand -hex 16` |
| `PLANE_API_URL` | Plane backend API the ticket-bridge POSTs issues to | `http://plane:8000/api/v1` — keep |
| `PLANE_API_KEY` | Plane API key for the bridge | generated inside Plane admin |
| `PLANE_WORKSPACE` | Plane workspace slug | set from Plane admin |
| `PLANE_PROJECT_ID` | Plane project UUID | set from Plane admin |
| `PLANE_UI_URL` | Plane UI URL for printed ticket links | `http://localhost:3010` |
| `PLANE_SECRET_KEY` | Plane Django secret (≥ 50 chars) | `openssl rand -hex 32` |
| `PLANE_DB_USER` | Plane Postgres user | `plane` |
| `PLANE_DB_PASSWORD` | Plane Postgres password (**URL-safe**: alnum + `-_`) | `openssl rand -hex 16` |
| `PLANE_DB_NAME` | Plane database | `plane` |
| `PLANE_MINIO_ACCESS_KEY` | Plane MinIO access key | `plane` |
| `PLANE_MINIO_SECRET_KEY` | Plane MinIO secret | `openssl rand -hex 16` |
| `PLANE_MQ_USER` | Plane RabbitMQ user | `plane` |
| `PLANE_MQ_PASSWORD` | Plane RabbitMQ password (**URL-safe**) | `openssl rand -hex 16` |
| `PROMETHEUS_IMAGE` | Prometheus pin | `prom/prometheus:latest` |
| `ALERTMANAGER_IMAGE` | Alertmanager pin | `prom/alertmanager:latest` |
| `PUSHGATEWAY_IMAGE` | Pushgateway pin | `prom/pushgateway:latest` |
| `GRAFANA_IMAGE` | Grafana pin | `grafana/grafana:latest` |
| `TICKET_BRIDGE_IMAGE` | ticket-bridge base image | `python:3.12-slim` |
| `PLANE_APP_RELEASE` | Plane backend/frontend release tag | `stable` |
| `PLANE_DB_IMAGE` | Plane Postgres pin | `postgres:15.7-alpine` |
| `PLANE_REDIS_IMAGE` | Plane Redis (Valkey) pin | `valkey/valkey:7.2.11-alpine` |
| `PLANE_MQ_IMAGE` | Plane RabbitMQ pin | `rabbitmq:3.13.6-management-alpine` |
| `PLANE_MINIO_IMAGE` | Plane MinIO (s3mock) pin | `adobe/s3mock:latest` |

> `BLACKBOX_EXPORTER_IMAGE` and `POSTGRES_EXPORTER_IMAGE` are referenced in
> `monitoring.yml` with inline defaults but are **not** in
> `monitoring.env.example`; they fall back to
> `prom/blackbox-exporter:latest` and
> `prometheuscommunity/postgres-exporter:latest`.

---

## 3. Bring-up order and commands

Base stack first (creates the shared `lms-poc` network), then monitoring, then
Traefik.

```bash
cd compose
cp .env.example .env                     # edit secrets (see §2a)
cp monitoring.env.example monitoring.env # edit secrets (see §2b)

# 1) base pipeline (project lms-poc; creates network `lms-poc`)
docker compose -f docker-compose.yml up -d

# 2) monitoring overlay (joins the shared network)
docker compose --env-file monitoring.env -f monitoring.yml up -d

# 3) edge proxy (Traefik)
docker compose -f traefik.yml up -d
```

The `Makefile` `deploy` target runs all three files in a **single merged
invocation** (equivalent `up`):

```bash
docker compose -f docker-compose.yml -f monitoring.yml -f traefik.yml up -d --pull always
```

- `--pull always` forces a re-pull of every image on each deploy (see
  `Makefile` `deploy:` target), so tag updates like `:latest` are picked up.
- In the merged command, `monitoring.env` is not loaded; monitoring services use
  inline defaults plus whatever is in `.env`. Prefer the three-step form above
  when you need Plane/Grafana driven by `monitoring.env`.

---

## 4. Service inventory

### `docker-compose.yml` (project `lms-poc`)

| Service | Image | Internal port | Host port | Traefik `Host` rule | Purpose |
|---|---|---|---|---|---|
| `lms-postgres` | `${POSTGRES_IMAGE:-postgres:16}` | 5432 | 5432 | — | Source LMS Postgres, `wal_level=logical` for Debezium |
| `lms-api` | build `../src/lms` | 8000 | 8000 | `lms.<domain>` → `lms-api:8000` | FastAPI service: `/health`, `/metrics`, `/generate`, `/loans/{id}/disburse`, `/payments` |
| `demo` | build `../demo` | 8000 | — (expose only) | `demo.<domain>` → `demo:8000` | Control panel driving pipeline scenarios |
| `minio` | `${MINIO_IMAGE:-adobe/s3mock:latest}` | 9000 | 9000 | `minio.<domain>` → `minio:9000` | S3 object store (Iceberg data files) |
| `polaris-postgres` | `${POSTGRES_IMAGE:-postgres:16}` | 5432 | 5433 | — | Polaris metadata DB |
| `polaris` | `${POLARIS_IMAGE:-apache/polaris:latest}` | 8181 | 8181 | `polaris.<domain>` → `polaris:8181` | Iceberg REST catalog |
| `polaris-setup` | `${POLARIS_SETUP_IMAGE:-alpine/curl:latest}` | — | — | — | One-shot: creates `lakehouse` catalog + bucket (`restart: "no"`) |
| `kafka` | `${KAFKA_IMAGE:-apache/kafka:3.8.1}` | 9092 | 9092 | — | Kafka broker (KRaft, combined broker+controller) |
| `connect` | `${CONNECT_IMAGE:-debezium/connect:2.7.3.Final}` | 8083 | 8083 | `connect.<domain>` → `connect:8083` | Kafka Connect (Debezium + Iceberg sink plugins) |
| `register-connectors` | `${POLARIS_SETUP_IMAGE:-alpine/curl:latest}` | — | — | — | One-shot: PUTs Debezium source + Iceberg sink configs (`restart: "no"`) |
| `trino` | `${TRINO_IMAGE:-trinodb/trino:latest}` | 8080 | 8080 | `trino.<domain>` → `trino:8080` | SQL engine over the Iceberg catalog |
| `dbt` | `${DBT_IMAGE:-onendo-dbt:latest}` (build `../dbt`) | — | — | — | One-shot: runs medallion pipeline + pushes metrics (`restart: "no"`) |
| `dagster-postgres` | `${POSTGRES_IMAGE:-postgres:16}` | 5432 | — | — | Dagster instance metadata (run history, schedule ticks) |
| `dagster` | `${DAGSTER_IMAGE:-onendo-dagster:latest}` (build `../dagster`) | 3000 | 3001 | `dagster.<domain>` → `dagster:3000` | Dagster webserver: UI + GraphQL |
| `dagster-daemon` | `${DAGSTER_IMAGE:-onendo-dagster:latest}` (build `../dagster`) | — | — | — | Dagster daemon: ticks `dbt_pipeline_schedule`, launches runs |
| `duckdb` | `${DUCKDB_IMAGE:-duckdb/duckdb:latest}` | — | — | — | Ad-hoc engine for virtualization demo (`profiles: ["demo"]`) |
| `metabase` | `${METABASE_IMAGE:-metabase/metabase:latest}` | 3000 | 8085 | `bi.<domain>` → `metabase:3000` | BI dashboards |
| `node-exporter` | `${NODE_EXPORTER_IMAGE:-prom/node-exporter:latest}` | 9100 | 9100 | — | Host metrics exporter |

### `monitoring.yml` (project `lms-monitoring`)

| Service | Image | Internal port | Host port | Traefik `Host` rule | Purpose |
|---|---|---|---|---|---|
| `prometheus` | `${PROMETHEUS_IMAGE:-prom/prometheus:latest}` | 9090 | 9090 | `prometheus.<domain>` → `prometheus:9090` | Scrapes all exporters |
| `alertmanager` | `${ALERTMANAGER_IMAGE:-prom/alertmanager:latest}` | 9093 | 9093 | `alertmanager.<domain>` → `alertmanager:9093` | Routes alerts to ticket-bridge |
| `pushgateway` | `${PUSHGATEWAY_IMAGE:-prom/pushgateway:latest}` | 9091 | 9091 | `pushgateway.<domain>` → `pushgateway:9091` | Receives dbt/test metrics |
| `blackbox-exporter` | `${BLACKBOX_EXPORTER_IMAGE:-prom/blackbox-exporter:latest}` | 9115 | 9115 | — | HTTP prober for s3mock/minio |
| `lms-postgres-exporter` | `${POSTGRES_EXPORTER_IMAGE:-prometheuscommunity/postgres-exporter:latest}` | 9187 | 9187 | — | CDC Postgres metrics |
| `kafka-lag-exporter` | `${CONNECT_IMAGE:-debezium/connect:2.7.3.Final}` | 9190 | 9190 | — | Consumer-group lag metrics |
| `grafana` | `${GRAFANA_IMAGE:-grafana/grafana:latest}` | 3000 | 3000 | `grafana.<domain>` → `grafana:3000` | Dashboards |
| `ticket-bridge` | `${TICKET_BRIDGE_IMAGE:-python:3.12-slim}` | 8001 | 8001 | — | Alertmanager → Plane webhook bridge |
| `plane-db` | `${PLANE_DB_IMAGE:-postgres:15.7-alpine}` | 5432 | — | — | Plane Postgres |
| `plane-redis` | `${PLANE_REDIS_IMAGE:-valkey/valkey:7.2.11-alpine}` | 6379 | — | — | Plane Redis |
| `plane-mq` | `${PLANE_MQ_IMAGE:-rabbitmq:3.13.6-management-alpine}` | 5672 | — | — | Plane RabbitMQ |
| `plane-minio` | `${PLANE_MINIO_IMAGE:-adobe/s3mock:latest}` | 9000 | — | — | Plane file uploads |
| `plane-migrator` | `makeplane/plane-backend:${PLANE_APP_RELEASE:-stable}` | — | — | — | One-shot DB migration (`restart: "on-failure"`) |
| `plane` | `makeplane/plane-backend:${PLANE_APP_RELEASE:-stable}` | 8000 | 8010 | `plane.<domain>` + `/api`,`/auth` → `plane:8000` | Plane backend API |
| `plane-worker` | `makeplane/plane-backend:${PLANE_APP_RELEASE:-stable}` | — | — | — | Plane async worker |
| `plane-web` | `makeplane/plane-frontend:v1.4.3` | 3000 | 3010 | `plane.<domain>` (default) → `plane-web:3000` | Plane frontend |
| `plane-admin` | `makeplane/plane-admin:v1.4.3` | 3000 | 3011 | `plane.<domain>` + `/god-mode` → `plane-admin:3000` | Plane admin wizard |

### `traefik.yml`

| Service | Image | Internal port | Host port | Purpose |
|---|---|---|---|---|
| `traefik` | `${TRAEFIK_IMAGE:-traefik:v3.2}` | 80 | 80 | Edge reverse proxy (file-based routing) |

---

## 5. Traefik routing + TLS

- **Entrypoints:** a single `web` entrypoint on `:80`
  (`traefik/traefik.yml`, `entryPoints.web.address: ":80"`).
- **TLS / cert resolver:** **there is none in Traefik.** TLS is terminated
  upstream by the GCP LB (managed cert for `*.onendo.cloud`), which forwards
  plain HTTP to Traefik on `:80`. There is no `certificatesResolvers:` block and
  no TLS section in `dynamic.yml`. Do not add one unless you move TLS to the VM.
- **Provider / "docker provider labels":** there are **no** Docker-provider
  labels on any service. Routing is **file-based**: static config declares
  `providers.file.filename: /etc/traefik/dynamic.yml` with `watch: true`
  (`traefik/traefik.yml`); all routers/services are declared explicitly in
  `traefik/dynamic.yml`.
- **How a new service gets a hostname:** add one `routers.<name>` entry and one
  `services.<name>` entry to `traefik/dynamic.yml`, pointing the service at the
  backend by its Compose service name on the `lms-poc` network
  (e.g. `url: http://<service>:<port>`). Host rules use Go templating to inject
  the base domain:

  ```yaml
  http:
    routers:
      mysvc:
        entryPoints: [web]
        rule: 'Host(`mysvc.{{ default "onendo.cloud" (env "DOMAIN") }}`)'
        service: mysvc
    services:
      mysvc:
        loadBalancer:
          servers:
            - url: http://mysvc:8080
  ```

  The file provider reloads on change (`watch: true`), so no Traefik restart is
  needed.
- **DNS records the managed cert needs:** all 12 SANs — `grafana`, `demo`, `bi`,
  `plane`, `trino`, `polaris`, `minio`, `connect`, `lms`, `prometheus`,
  `alertmanager`, `pushgateway` — must resolve to the LB IP before GCP issues the
  cert (it is **not** a wildcard; see `terraform/gcp/network/main.tf`).
  (`docs/architecture.md` labels only `grafana`/`demo`/`bi`/`plane` "public", but
  the managed cert and the Traefik routers cover all 12 names.)
- **`dagster.<domain>` (added router, cert SAN pending):** the router exists in
  `dynamic.yml`, but the managed cert's SAN list does **not** include `dagster`
  yet, so HTTPS through the LB fails until `terraform/gcp/network/main.tf` gains
  that SAN (a cert re-issue — architecture change, needs approval). Until then
  use `http://<vm-ip>:3001`.

---

## 6. Persistence — what to back up

### Named volumes (state — back these up)

**`docker-compose.yml`:**

| Volume | Mounted at | Holds |
|---|---|---|
| `lms_pg_data` | `lms-postgres:/var/lib/postgresql/data` | Source LMS data |
| `polaris_pg_data` | `polaris-postgres:/var/lib/postgresql/data` | Polaris metadata |
| `minio_data` | `minio:/s3mockroot` | Iceberg data files (object store) |
| `kafka_data` | `kafka:/var/lib/kafka/data` | Kafka log segments / offsets |
| `connect_config` | `connect:/kafka/config` | Connect worker config |
| `connect_data` | `connect:/kafka/data` | Connect state |
| `connect_logs` | `connect:/kafka/logs` | Connect logs |
| `metabase_data` | `metabase:/metabase-data` | Metabase app DB (`MB_DB_FILE`) |
| `dagster_pg_data` | `dagster-postgres:/var/lib/postgresql/data` | Dagster run history / schedule ticks |
| `prometheus_data` | (used by `monitoring.yml` `prometheus:/prometheus`) | TSDB |
| `grafana_data` | (used by `monitoring.yml` `grafana:/var/lib/grafana`) | Grafana state |

(`prometheus_data`/`grafana_data` are declared in `docker-compose.yml` but the
services live in `monitoring.yml`; the volumes are re-declared there.)

**`monitoring.yml`:**

| Volume | Mounted at | Holds |
|---|---|---|
| `prometheus_data` | `prometheus:/prometheus` | Prometheus TSDB (15d retention) |
| `alertmanager_data` | `alertmanager:/alertmanager` | Alertmanager silences |
| `grafana_data` | `grafana:/var/lib/grafana` | Grafana dashboards/state |
| `plane_pg_data` | `plane-db:/var/lib/postgresql/data` | Plane DB |
| `plane_redis_data` | `plane-redis:/data` | Plane Redis |
| `plane_mq_data` | `plane-mq:/var/lib/rabbitmq` | Plane RabbitMQ |
| `plane_minio_data` | `plane-minio:/s3mockroot` | Plane uploads |

### Bind mounts (config from the repo — in git, not backed up)

- `../monitoring/jmx` → `polaris`, `kafka`, `connect`, `trino` (ro) — JMX exporter
  jar + configs.
- `./polaris` → `polaris-setup` (ro) — `init-lakehouse.sh`.
- `./connectors` → `register-connectors` (ro) — connector JSON templates + script.
- `./trino/catalog` → `trino:/etc/trino/catalog` (ro) — `lakehouse.properties`.
- `./demo` → `trino:/demo`, `duckdb:/demo` (ro) — demo SQL.
- `../dbt` → `dbt:/dbt` — dbt project (built + mounted).
- `../dbt` → `dagster:/dbt`, `dagster-daemon:/dbt` (rw) — the job shells out to
  `scripts/run-and-push-metrics.sh` in the same project, so dbt writes `target/`
  and `logs/` in place exactly as the one-shot service does.
- `./connect-plugins` → `connect:/kafka/connect/iceberg-sink` — sink plugin.
- `../monitoring/prometheus/{prometheus.yml,rules}` → `prometheus` (ro).
- `../monitoring/alertmanager/alertmanager.yml` → `alertmanager` (ro).
- `../monitoring/lag-exporter` → `kafka-lag-exporter` (ro).
- `../monitoring/grafana/{provisioning,dashboards}` → `grafana` (ro).
- `../monitoring/scripts/ticket-bridge.py` → `ticket-bridge` (ro).
- `./plane-admin/nginx.conf` → `plane-admin` (ro).
- `./traefik/{traefik.yml,dynamic.yml}` → `traefik` (ro).

---

## 7. Health / verification

```bash
cd compose
docker compose -f docker-compose.yml -f monitoring.yml -f traefik.yml ps
```

Per-service smoke checks (run from `compose/`; port numbers are the published
host ports):

```bash
# Postgres (source LMS)
docker compose -f docker-compose.yml exec lms-postgres psql -U lms -d lms -c 'select 1;'

# Kafka — the exact healthcheck used in docker-compose.yml
docker compose -f docker-compose.yml exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list

# Trino (healthcheck endpoint + CLI)
curl -fsS http://localhost:8080/v1/info
docker compose -f docker-compose.yml exec trino trino --execute 'SHOW CATALOGS'

# Kafka Connect
curl -fsS http://localhost:8083/connectors

# Metabase
curl -fsS http://localhost:8085/api/health

# MinIO (s3mock — no native health endpoint; expect a 2xx/3xx/4xx HTTP code)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9000/

# Polaris (REST token endpoint from init-lakehouse.sh — confirms the port is up)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8181/api/catalog/v1/oauth/tokens

# Prometheus / Alertmanager / Pushgateway
curl -fsS http://localhost:9090/-/ready
curl -fsS http://localhost:9093/-/ready
curl -fsS http://localhost:9091/-/healthy

# Grafana
curl -fsS http://localhost:3000/api/health

# Exporters
curl -fsS http://localhost:9100/metrics | head        # node-exporter
curl -fsS http://localhost:9187/metrics | head        # postgres-exporter
curl -fsS http://localhost:9190/metrics | head        # kafka-lag-exporter

# Blackbox probe of minio (the scrape target)
curl -fsS 'http://localhost:9115/probe?module=http_2xx&target=http://minio:9000/favicon.ico'

# Plane
curl -fsS http://localhost:8010/          # backend API
curl -fsS http://localhost:3010/          # frontend
curl -fsS http://localhost:3011/god-mode/ # admin wizard

# dbt (one-shot) — inspect exit status + pushed metrics
docker compose -f docker-compose.yml logs dbt

# Dagster — UI, code location, and the dbt job/schedule
curl -fsS http://localhost:3001/server_info            # UI up (host 3001 → container 3000)
docker compose -f docker-compose.yml logs dagster | tail   # code location loaded, no import errors
docker compose -f docker-compose.yml logs dagster-daemon | tail  # schedule ticks
# GraphQL: confirm the job + schedule exist, and read the last run's status
# (jobs/schedules hang off repositories, not off the location entry)
curl -fsS http://localhost:3001/graphql -H 'Content-Type: application/json' -d '{"query":"{ workspaceOrError { ... on Workspace { locationEntries { name locationOrLoadError { ... on RepositoryLocation { repositories { name jobs { name } schedules { name cronSchedule scheduleState { status } } } } } } } } }"}'
curl -fsS http://localhost:3001/graphql -H 'Content-Type: application/json' -d '{"query":"{ runsOrError(limit: 3) { ... on Runs { results { runId jobName status } } } }"}'
```

Traefik routing can be verified by hitting a host through the proxy, e.g.
`curl -sH 'Host: grafana.onendo.cloud' http://localhost/` (Traefik routes by
`Host` header).

---

## 8. Restart policies and boot order

**Restart policies:** every long-running service uses `restart: unless-stopped`.
One-shot jobs use `restart: "no"` (`polaris-setup`, `register-connectors`,
`dbt`); `plane-migrator` uses `restart: "on-failure"`. `duckdb` is
`profiles: ["demo"]`, so it is **not** started by a plain `up -d`.

**Boot-order dependencies** (`depends_on`):

- `lms-api` → `lms-postgres`; `demo` → `lms-api`.
- `polaris` → `polaris-postgres`.
- `polaris-setup` → `minio` (`service_started`), `polaris` (`service_started`).
- `connect` → `kafka`.
- `register-connectors` → `connect` (`service_started`), `minio`
  (`service_started`), `polaris-setup` (`service_completed_successfully`).
- `trino` → `minio`, `polaris` (`service_started`), `polaris-setup`
  (`service_completed_successfully`); **has a healthcheck**
  (`curl /v1/info`).
- `dbt` → `trino` (`service_healthy`).
- `dagster` → `dagster-postgres` (`service_healthy`), `trino` (`service_healthy`).
- `dagster-daemon` → `dagster-postgres` (`service_healthy`), `dagster`
  (`service_started`), `trino` (`service_healthy`). The daemon is what ticks
  `dbt_pipeline_schedule` — without it the schedule never fires.
- `metabase` → `trino`.
- `prometheus` → `alertmanager`, `pushgateway`.
- `kafka-lag-exporter` → `kafka`.
- `grafana` → `prometheus`.
- `ticket-bridge` → `plane`.
- `plane-migrator` → `plane-db`, `plane-redis`, `plane-mq`.
- `plane` → `plane-db`, `plane-redis`, `plane-mq`, `plane-minio`.
- `plane-worker` → `plane`, `plane-db`, `plane-redis`, `plane-mq`, `plane-minio`.
- `plane-web` / `plane-admin` → `plane`.

**Healthchecks** (used by `service_healthy`): `lms-postgres` (`pg_isready`),
`kafka` (`kafka-topics.sh --list`), `trino` (`curl /v1/info`), `dagster`
(`python -c urllib /server_info`), `dagster-postgres` (`pg_isready`).

**After a VM reboot:** all `unless-stopped` services restart automatically
(including Traefik). The one-shot jobs (`polaris-setup`, `register-connectors`,
`dbt`) do **not** re-run on their own because their restart policy is `no`.
Re-running `docker compose … up -d` re-runs them (`register-connectors` is
idempotent PUT-upsert and re-registers on every `up -d`, per its comment in
`docker-compose.yml`); `dbt` is re-run explicitly with
`docker compose up -d --force-recreate dbt` or `docker compose run --rm dbt`.

---

## 9. Common failures

- **Port conflicts** — the stack binds many host ports: `5432`, `5433`, `8000`,
  `8080`, `8083`, `8085`, `8181`, `9000`, `9090`, `9091`, `9092`, `9093`,
  `9100`, `9115`, `9187`, `9190`, `8001`, `8010`, `3010`, `3011`, `3000`, `80`.
  A local Postgres/Kafka/Traefik on the host will collide. Check
  `docker compose ps` exit codes and `ss -ltnp`; free the port or change the
  `ports:` mapping.
- **Cert not issuing** — TLS is the GCP LB's job, not Traefik's. If the managed
  cert is stuck, the cause is DNS: **all 12 SANs** (`grafana`, `demo`, `bi`,
  `plane`, `trino`, `polaris`, `minio`, `connect`, `lms`, `prometheus`,
  `alertmanager`, `pushgateway`) must resolve to the LB IP *before* GCP
  provisions the certificate (it is not a wildcard). Traefik itself only needs
  `:80`.
- **Container OOM** — every service has a `mem_limit` (e.g. Kafka/Connect
  1536m, Trino 2048m, Metabase 2g). JVMs are bounded via `JAVA_TOOL_OPTIONS`
  (`-XX:MaxRAMPercentage=75` / `-Xmx…`). If a service restarts with exit 137,
  raise its `mem_limit` and matching `-Xmx` together — the total must fit the
  16 GB budget.
- **`.env` typos** — a mistyped variable name silently falls back to the inline
  default (e.g. `${LMS_DB_PASSWORD:-lms}`), so you can run with the `lms`
  placeholder password without noticing. `docker compose config` resolves and
  prints the effective configuration — grep it for `CHANGE_ME` / placeholder
  passwords before treating the stack as secure. Also: `POLARIS_CLIENT_SECRET`
  must not contain `:` (breaks Trino's `id:secret` credential), and Plane
  DB/MQ passwords must be URL-safe.
- **Monitoring reaches nothing** — `monitoring.yml` services join the shared
  `lms-poc` network only when the base stack (which declares that network) is up
  or the three files are merged in one `up`. If `prometheus` can't resolve
  `minio`/`kafka`, the base stack is down or was brought up in a different
  project/network.
- **`demo` control panel** — `demo` is only `expose`d (not published), so it is
  reachable solely via Traefik at `demo.<domain>`; `curl http://localhost:8000`
  hits `lms-api`, not the control panel.

---

Produced by: Keel · Reviewed by: Ledger
