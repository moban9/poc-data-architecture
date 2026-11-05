# 05 — Monitoring & auto-recovery (operator runbook)

How the POC observes itself, what fires, and how to bring it back after a reboot.
Every job name, alert, port, env var, and command below exists in the repo; source
files are cited inline. Grounded in `monitoring/`, `compose/monitoring.yml`,
`compose/docker-compose.yml`, `compose/traefik*.yml`, and `scripts/`.

Secrets are never printed here — copy `compose/.env.example → .env` and
`compose/monitoring.env.example → monitoring.env` and change every password.

---

## 1. What is observed and why

Prometheus (`prom/prometheus:latest`, port `9090`) scrapes on a 15s interval
(`scrape_interval` / `evaluation_interval`), with external labels `env=poc`,
`stack=lms`, and 15d retention (`--storage.tsdb.retention.time=15d`). Config is
`monitoring/prometheus/prometheus.yml`; rules are `monitoring/prometheus/rules/*.yml`.

Scrape jobs (real `job_name` → target → exporter):

| job_name            | target                          | exporter / what it answers |
|---------------------|---------------------------------|----------------------------|
| `prometheus`        | `localhost:9090`                | Prometheus self-scrape      |
| `alertmanager`      | `alertmanager:9093`             | Alertmanager self-scrape    |
| `pushgateway`       | `pushgateway:9091` (`honor_labels: true`) | metrics pushed by dbt/Dagster + demo |
| `node-exporter`     | `node-exporter:9100`            | host metrics (CPU/mem/disk) |
| `minio`             | `http://minio:9000/favicon.ico` via `blackbox-exporter:9115` | blackbox `http_2xx` probe of s3mock |
| `kafka`             | `kafka:7071`                    | JMX javaagent (catch-all `.*`) |
| `connect`           | `connect:7072`                  | JMX javaagent + `kafka_connect_connector_status` |
| `trino`             | `trino:7073`                    | JMX javaagent (catch-all `.*`) |
| `polaris`           | `polaris:7074`                  | JMX javaagent (catch-all `.*`) |
| `lms-postgres`      | `lms-postgres-exporter:9187`    | `postgres_exporter` for the CDC source DB |
| `kafka-lag-exporter`| `kafka-lag-exporter:9190`       | custom lag sidecar → `kafka_consumergroup_lag` |
| `lms`               | `lms-api:8000`                  | LMS FastAPI `/metrics` (`prometheus_client`) |

Notes:

- **JMX exporters** (`monitoring/jmx/*.yml`, port `7071`–`7074`) are attached to each
  JVM via `JAVA_TOOL_OPTIONS=-javaagent:/opt/jmx/jmx_prometheus_javaagent.jar=<port>:/opt/jmx/<svc>.yml`
  (`kafka.yml`, `connect.yml`, `trino.yml`, `polaris.yml`). `connect.yml` is the only
  one with a non-catch-all rule: it maps the Connect framework MBean status string
  into `kafka_connect_connector_status{connector,status}` (gauge value `1`).
- **Lag exporter** (`monitoring/lag-exporter/kafka-lag-exporter.py`) reuses the
  Connect image, runs `kafka-consumer-groups.sh --describe --all-groups` every
  `SCRAPE_INTERVAL` (10s), sums per-partition LAG into
  `kafka_consumergroup_lag{group,topic}`, and serves it on `:9190`. On failure it
  emits `kafka_consumergroup_lag_export_error 1` instead.
- **MinIO/s3mock** has no native Prometheus endpoint and its minimal JRE can't host
  the JMX agent, so liveness is a blackbox `http_2xx` probe of `/favicon.ico`.
- **Postgres exporter** (`prometheuscommunity/postgres-exporter`) connects to the CDC
  source via `DATA_SOURCE_NAME="postgresql://<lms-user>@lms-postgres:5432/lms?sslmode=disable"`.
  Only `lms-postgres` is exported — `polaris-postgres` has no exporter.
- **No cAdvisor.** `node-exporter` is the only host-level metrics source.
- **Pushgateway** receives (job `dbt`): `dbt_run_success{layer=...}` (1/0),
  `dbt_test_failures`, `dbt_tests_total`, `quarantine_rows_total` — pushed by
  `dbt/scripts/run-and-push-metrics.sh` after each run — and `demo_failure{stage=...}`
  (1 = failed) pushed by the demo panel (`demo/app.py`) to tint the Grafana topology.

---

## 2. Alert catalogue

Rules live in `monitoring/prometheus/rules/pipeline.yml`. The `pipeline_topology`
group only builds **recording rules** (not alerts): `pipeline_stage_health{stage}`,
`pipeline_stage_health_effective` (real health overridden by `demo_failure`), and
`pipeline_stage_edge{source,target}` — all consumed by the Grafana Node Graph.

The `pipeline_alerts` group defines five alerts:

| Alert | Severity | `for` | Expression |
|-------|----------|-------|------------|
| `KafkaConnectConnectorFailed` | critical (`component: connect`) | 1m | `kafka_connect_connector_status{status="failed"} == 1` |
| `KafkaConsumerLagTooHigh` | warning (`component: kafka`) | 5m | `max by (group, topic) (kafka_consumergroup_lag) > 10000` |
| `DbtTestFailures` | warning (`component: dbt`) | 5m | `dbt_test_failures > 0` |
| `QuarantineRowsPresent` | warning (`component: dbt`) | 5m | `quarantine_rows_total > 0` |
| `ServiceDown` | critical (`component: infrastructure`) | 2m | `up{job=~"node-exporter\|kafka\|connect\|trino\|polaris\|lms-postgres\|lms"} == 0 or probe_success{job="minio"} == 0` |

Operator action per alert:

- **KafkaConnectConnectorFailed** — a connector is in `FAILED`. Check
  `curl -s http://connect:8083/connectors/<connector>/status` (the rule's own hint),
  inspect the Connect task logs (`docker compose logs connect`), then re-register the
  connector (idempotent PUT — see §7) or restart Connect.
- **KafkaConsumerLagTooHigh** — a consumer group is > 10,000 messages behind on a
  topic; the sink is falling behind. Confirm with
  `curl -s http://localhost:9190/metrics`, then check the sink connector status and
  Connect task throughput.
- **DbtTestFailures** — one or more dbt data tests failed in the last run. This is
  *expected* on dirty source data (the DQ gate catching bad rows — see
  `dbt/scripts/run-and-push-metrics.sh`). Investigate which test failed; failing rows
  are quarantined, not loaded.
- **QuarantineRowsPresent** — the last Silver/Gold load quarantined rows. Pull the
  count from `lakehouse.quarantine_lms.quarantine_lms` and investigate the dirty rows.
- **ServiceDown** — a scrape target has been down 2m. `docker compose ps` first; if the
  host-level `node-exporter` is down, the inhibition rule suppresses the rest.

---

## 3. Alertmanager: routing, receivers, tickets

`monitoring/alertmanager/alertmanager.yml`, `prom/alertmanager:latest` on `:9093`.

- **Routing tree**: single default receiver `plane-ticket-bridge`; grouping
  `group_by: [alertname, severity, component]`; `group_wait: 30s`,
  `group_interval: 5m`, `repeat_interval: 4h`. A child route matches
  `severity="critical"` and tightens to `group_wait: 10s`, `repeat_interval: 1h`.
  `resolve_timeout: 5m`.
- **Receiver**: `plane-ticket-bridge` → webhook `POST http://ticket-bridge:8001/alerts`
  with `send_resolved: true`.
- **Inhibition**: if `ServiceDown` fires with `job="node-exporter"`, it suppresses all
  other `ServiceDown` alerts on the same `instance` (the host is the root cause).

**How tickets are created** — `monitoring/scripts/ticket-bridge.py`
(`python:3.12-slim`, port `8001`):

- Endpoints: `GET /health` (liveness + `configured` flag), `POST /alerts` (also
  accepts `/alert`, `/`).
- Env: `PLANE_API_URL` (default `http://plane:8000/api/v1`), `PLANE_API_KEY` (sent as
  `X-API-Key`), `PLANE_WORKSPACE`, `PLANE_PROJECT_ID`, `PLANE_UI_URL` (default
  `http://localhost:3010`), `BRIDGE_PORT` (8001), `BRIDGE_DEDUPE_TTL` (3600),
  `BRIDGE_DRY_RUN` (`1`/`true`/`yes` = log only).
- Each **firing** alert becomes one Plane issue:
  `POST {PLANE_API_URL}/workspaces/{PLANE_WORKSPACE}/projects/{PLANE_PROJECT_ID}/issues/`
  with `{name, description_html, priority}`. Severity→priority map:
  `critical→urgent`, `page→urgent`, `error/warning→high`, `info→low`, else `medium`.
- **Dedup is in-memory** (no queue file): an sha256 fingerprint of
  `alertname + sorted non-ephemeral labels` is kept in `_seen` with
  `BRIDGE_DEDUPE_TTL` (default 3600s). **Resolved** alerts are only logged — no
  ticket, no issue-close. A batch that fails *entirely* returns `502` so Alertmanager
  retries; partial failures return `200` (dedup + `repeat_interval` cover the rest).
  If `PLANE_API_KEY/WORKSPACE/PROJECT_ID` are unset, `/alerts` returns `500`.

**Silencing / dedup how-to**:

- Grouping + `repeat_interval` (4h, 1h for critical) already throttle re-notifies;
  the bridge's TTL dedup adds a second layer against duplicate tickets.
- To silence: Alertmanager UI at `https://alertmanager.onendo.cloud` (Traefik route),
  or the v2 API:

```bash
curl -s -X POST http://localhost:9093/api/v2/silences \
  -H 'Content-Type: application/json' \
  -d '{"matchers":[{"name":"alertname","value":"KafkaConsumerLagTooHigh","isRegex":false,"isEqual":true}],"startsAt":"'$(date -u +%FT%TZ)'","endsAt":"'$(date -u -d '+2 hours' +%FT%TZ)'","createdBy":"operator","comment":"sink lag under investigation"}'
```

---

## 4. Grafana

`grafana/grafana:latest` on `:3000`; provisioning is baked in read-only:

- **Provisioning path**: `../monitoring/grafana/provisioning` → `/etc/grafana/provisioning`
  (datasources + dashboard providers); dashboards mount
  `../monitoring/grafana/dashboards` → `/var/lib/grafana/dashboards`.
- **Datasource**: `Prometheus` (uid `prometheus`, type `prometheus`,
  `url: http://prometheus:9090`, `access: proxy`, `isDefault: true`,
  `editable: false`, `timeInterval: 15s`).
- **Dashboard provider**: `lms-pipeline` (file type, `path: /var/lib/grafana/dashboards`,
  `updateIntervalSeconds: 30`, `allowUiUpdates: true`).
- **Default login**: `GF_SECURITY_ADMIN_USER=${GRAFANA_USER:-admin}`,
  `GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD:-grafana}`,
  `GF_USERS_ALLOW_SIGN_UP=false`. (`monitoring.env.example` sets
  `GRAFANA_USER=admin` / `GRAFANA_PASSWORD=CHANGE_ME_grafana`.)

Dashboard **“LMS Pipeline Health”** (uid `lms-pipeline-health`, refresh 30s, window
`now-6h`, tags `lms/pipeline/poc/monitoring`) — panels:

| Panel title | Type | What it answers |
|-------------|------|-----------------|
| Pipeline topology (colored by live health) | nodeGraph | Which stage is up/down; node color = `pipeline_stage_health_effective` (0=red, 1=green) over `LMS → Debezium → Kafka → Iceberg → Bronze → Silver → Gold → BI` |
| Pipeline lag (consumer group lag) | timeseries | `max by (group,topic) (kafka_consumergroup_lag)` — is the sink keeping up |
| Kafka Connect connector status | timeseries | `count by (connector,status) (kafka_connect_connector_status)` — RUNNING vs FAILED |
| Quarantine row count | timeseries (bars) | `quarantine_rows_total` — how many rows the DQ gate quarantined |
| dbt test results | timeseries | `dbt_test_failures` vs `dbt_tests_total` |
| Services up | timeseries (bool 0/1) | `up{job=~"node-exporter\|kafka\|connect\|trino\|polaris\|lms-postgres\|lms"} or probe_success{job="minio"}` |

Reachable at `http://localhost:3000` (published) and `https://grafana.onendo.cloud`
(Traefik).

---

## 5. Bring-up & verification

The repo's canonical command (used by `make deploy`, `.github/workflows/deploy.yml`,
and `scripts/poc-stack.service`) merges all three overlays from the `compose/` dir:

```bash
cd /home/ubuntu/poc/compose
docker compose -f docker-compose.yml -f monitoring.yml -f traefik.yml up -d --pull always
```

`monitoring.yml`'s own header documents a standalone monitoring-only path (requires
the main stack already up, since it joins the shared `lms-poc` network):

```bash
cd compose
docker compose --env-file monitoring.env -f monitoring.yml up -d
```

Secrets: `compose/.env` (from `.env.example`) auto-loads; `monitoring.env` (from
`monitoring.env.example`) is read only via `--env-file`.

Verify each component from the host (published ports):

1. **Prometheus ready**: `curl -s http://localhost:9090/-/ready` → `Prometheus Server is Ready.`
2. **Targets up**: `curl -s http://localhost:9090/api/v1/targets` — every job should show `"health":"up"`. Down targets: `curl -s 'http://localhost:9090/api/v1/query?query=up%20%3D%3D%200'` (empty result = all up).
3. **Alertmanager**: `curl -s http://localhost:9093/-/ready`; status `curl -s http://localhost:9093/api/v2/status`.
4. **Grafana**: `curl -s http://localhost:3000/api/health` → `{"database":"ok",...}`.
5. **Pushgateway**: `curl -s http://localhost:9091/metrics`.
6. **Lag exporter**: `curl -s http://localhost:9190/metrics` → should contain `kafka_consumergroup_lag` (not `_export_error 1`).
7. **Postgres exporter**: `curl -s http://localhost:9187/metrics`.
8. **ticket-bridge**: `curl -s http://localhost:8001/health` → `{"status":"ok","configured":true}` (`configured:true` means the Plane env is set).

---

## 6. Firing a test incident

**A. Direct Plane ticket (the repo's `scripts/incident-simulator.py`)** — exercises
Plane + credentials, but *not* the Prometheus→Alertmanager path (it POSTs to Plane
directly). Default `PLANE_API_URL` is the in-network `http://plane:8000/api/v1`; from
the host override it (Plane is published on `:8010`):

```bash
cd /home/ubuntu/poc/scripts
PLANE_API_KEY=… PLANE_WORKSPACE=… PLANE_PROJECT_ID=… \
PLANE_API_URL=http://localhost:8010/api/v1 \
INCIDENT_TYPE="data-quality" INCIDENT_MSG="Gold freshness check failed" \
python3 incident-simulator.py
```

Expected: `✅ incident ticket created — id <id>` + a link; the issue is titled
`[INCIDENT] data-quality: Gold freshness check failed` with `priority: urgent`.
Resolve by closing the issue in Plane (`https://plane.onendo.cloud/<workspace>/projects/<project>/issues/<id>`).
(The demo panel's `incident` scenario in `demo/app.py` does the same thing and also
pushes `demo_failure{stage="Gold"} = 1` to the pushgateway.)

**B. Full alert path** (Prometheus → Alertmanager → ticket-bridge → Plane). Stop a
scraped service so a real rule fires:

```bash
cd /home/ubuntu/poc/compose
docker compose -f docker-compose.yml -f monitoring.yml -f traefik.yml stop connect
```

After 2m `ServiceDown` fires (job `connect`, critical → `group_wait: 10s`) →
ticket-bridge → Plane issue `[Monitoring] ServiceDown: …`. (Stopping `connect`
takes its in-container JMX exporter down, so `kafka_connect_connector_status`
vanishes and the connector-status alert cannot fire here; `ServiceDown` is what
fires.)
Resolve: `docker compose -f docker-compose.yml -f monitoring.yml -f traefik.yml start connect`
and close the Plane issue; the alert resolves and `send_resolved: true` makes the
bridge log (not ticket) the resolution.

---

## 7. Auto-recovery on reboot

Docker is enabled at boot (`scripts/bootstrap.sh` runs `systemctl enable --now docker`),
so every `restart: unless-stopped` container comes back on VM reboot.

| Restart policy | Services | Reboot behavior |
|----------------|----------|-----------------|
| `unless-stopped` | main: `lms-postgres`, `lms-api`, `demo`, `minio`, `polaris-postgres`, `polaris`, `kafka`, `connect`, `trino`, `metabase`, `node-exporter` (plus `duckdb`, profile `demo`); monitoring: `prometheus`, `alertmanager`, `pushgateway`, `blackbox-exporter`, `lms-postgres-exporter`, `kafka-lag-exporter`, `grafana`, `ticket-bridge`, `plane-db`, `plane-redis`, `plane-mq`, `plane-minio`, `plane`, `plane-worker`, `plane-web`, `plane-admin`; edge: `traefik` | **Come back automatically** |
| `on-failure` | `plane-migrator` | Runs migrations, exits 0; stays exited (harmless) |
| `no` | `polaris-setup`, `register-connectors`, `dbt` | **Do NOT come back** (one-shots) |

Healthchecks that gate dependents (only during `up -d` ordering — not on daemon
restart, which restarts each `unless-stopped` container independently):
`lms-postgres` `pg_isready`; `kafka` `kafka-topics.sh --list`; `trino`
`curl /v1/info`. `dbt` waits on `trino: service_healthy`; `register-connectors` waits
on `connect`/`minio: service_started` + `polaris-setup: service_completed_successfully`;
`trino`/`polaris-setup` wait on `polaris-setup: service_completed_successfully`.

**What does NOT come back by itself + exact restore commands** (all from
`cd /home/ubuntu/poc/compose`):

1. **Connector registration** (`register-connectors`, `restart: "no"`). Registered
   configs persist in the Kafka config topic (`connect_config` volume + `kafka_data`),
   so Connect re-reads them on restart — but the idempotent re-registration only
   happens when the one-shot re-runs:

   ```bash
   docker compose -f docker-compose.yml -f monitoring.yml -f traefik.yml run --rm register-connectors
   ```

2. **Polaris `lakehouse` catalog** (`polaris-setup`, `restart: "no"`). The init script
   is idempotent (skips if the catalog already exists):

   ```bash
   docker compose -f docker-compose.yml -f monitoring.yml -f traefik.yml run --rm polaris-setup
   ```

3. **dbt one-shot** (`dbt`, `restart: "no"`):

   ```bash
   docker compose -f docker-compose.yml -f monitoring.yml -f traefik.yml run --rm dbt
   ```

4. **dbt schedule** — the 2-minute cron (`scripts/dbt-schedule.sh` →
   `docker compose run --rm dbt`) is superseded by the Dagster schedule
   `dbt_pipeline_schedule` (`dagster/code/definitions.py`, cadence from
   `DAGSTER_DBT_CRON`, default `*/15 * * * *`). The cron line is **no longer
   installed** on the VM (`crontab -l` is empty; verified 2026-11-05). A slow dbt
   run is serialised by the `dbt` concurrency tag (`dagster/dagster.yaml`), so a
   tick cannot overlap a still-running rebuild. Do not lower the cadence below
   the rebuild time — see docs/09 §6.1/§9.6 and kanban t_1184e3c6.

5. **systemd unit** — `scripts/poc-stack.service` ships in the repo but is **not
   installed or enabled** by `bootstrap.sh` or any workflow. To get systemd-managed
   bring-up on boot, install it manually (it hardcodes `WorkingDirectory=/home/ubuntu/poc/compose`,
   `User=ubuntu`, and `docker compose -f docker-compose.yml -f monitoring.yml -f traefik.yml up -d`):

   ```bash
   sudo cp /home/ubuntu/poc/scripts/poc-stack.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now poc-stack
   ```

> On a plain reboot (no `up -d`), the one-shots above stay exited. Re-running the
> full bring-up command also re-triggers them (`register-connectors` is documented in
> `docker-compose.yml` to re-run on every `up -d`).

---

## 8. Failure modes

- **Exporter down** — `ServiceDown` fires after 2m for `node-exporter|kafka|connect|trino|polaris|lms-postgres|lms`
  (or `probe_success{minio}==0`). If `node-exporter` is down, the inhibition rule
  silences the rest (host is the root cause). Check `docker compose ps` + `docker compose logs <svc>`.
- **Alert flapping** — `for:` clauses (1m/2m/5m) absorb transient blips; `group_interval: 5m`
  and `repeat_interval: 4h` (1h critical) bound re-notification. If an alert bounces,
  raise its `for:` or silence it (§3).
- **Ticket spam** — two layers: Alertmanager grouping + `repeat_interval`, and the
  bridge's in-memory `BRIDGE_DEDUPE_TTL` dedup. Set `BRIDGE_DRY_RUN=1` to test the
  bridge without POSTing. Note the bridge keeps no persistent state, so a bridge
  restart resets dedup.
- **Missing volume after recreate** — named volumes (`prometheus_data`,
  `alertmanager_data`, `grafana_data`, `plane_*_data`, and the main stack's
  `lms_pg_data`, `kafka_data`, `connect_*`, `minio_data`, `metabase_data`) persist
  across `down`/`up`; a `docker compose down -v` (or volume prune) destroys TSDB,
  silences, Grafana dashboards/login, and all pipeline data. Recreate deliberately,
  then re-run the one-shots from §7.

---

Produced by: Relay · Reviewed by: Ledger
