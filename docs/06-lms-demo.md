# LMS Source + Demo Control Panel — Operator Runbook

Manual-setup reference for the two "front door" components of the POC: the
**LMS source service** (`src/lms/`) that writes dirty/clean loans into Postgres,
and the **demo control panel** (`demo/`) that drives scenarios over the pipeline.
Every route, table, column, scenario name, and env var below is taken verbatim
from the code; nothing is invented.

- LMS = FastAPI REST API over a Postgres source DB (`borrower`, `loan`, `loan_event`).
- Demo = a second FastAPI harness + a self-contained static page that runs four
  scenarios against the real pipeline (or simulates when a subsystem is unreachable).

---

## 1. The LMS source service (`src/lms/`)

Files: `app.py` (FastAPI + routes), `models.py` (SQLAlchemy tables), `db.py`
(engine/session), `constants.py` (dirty modes + seed borrowers), `seed.py`
(idempotent schema+seed), `requirements.txt`, `Dockerfile`,
`docker-compose.lms-api.yml` (a canonical snippet; the main compose already
declares `lms-api`).

### 1.1 What it models — real tables and columns

Defined in `src/lms/models.py`. **Deliberately no foreign-key or CHECK
constraints** — the source is allowed to emit exactly the defects the downstream
dbt Silver tests catch. `origination_date` is `VARCHAR` by design so the invalid
value `"not-a-date"` can be stored and later trip the `valid_date` test.

| Table | Column | Type | Constraints |
|---|---|---|---|
| `borrower` | `id` | `String(32)` | PK |
| | `full_name` | `String(255)` | NOT NULL |
| `loan` | `id` | `String(32)` | PK |
| | `amount` | `Numeric(18,2)` | NOT NULL |
| | `currency` | `String(8)` | NOT NULL |
| | `origination_date` | `String(16)` | NOT NULL (VARCHAR on purpose) |
| | `borrower_id` | `String(32)` | NOT NULL, index `ix_loan_borrower_id` |
| `loan_event` | `id` | `String(32)` | PK |
| | `loan_id` | `String(32)` | **nullable** (a NULL here is one engineered dirty mode) |
| | `event_type` | `String(32)` | NOT NULL (`origination` / `disbursement` / `payment`) |
| | `amount` | `Numeric(18,2)` | nullable (payment/disbursement enrichment) |
| | `occurred_at` | `DateTime(timezone=True)` | NOT NULL, index `ix_loan_event_loan_id` |

### 1.2 How it is seeded

`seed.py` is idempotent (`CREATE TABLE IF NOT EXISTS` + `INSERT … ON CONFLICT DO
NOTHING`). It blocks on `wait_for_db()` (30 retries × 2s), creates the three
tables via `Base.metadata.create_all`, then upserts the four valid borrowers:

- `B-1001` Alice Example · `B-1002` Bob Example · `B-1003` Carol Example · `B-1004` Dave Example

These mirror `dbt/seeds/borrowers.csv` (which currently backs `dim_borrower`).
The `Dockerfile` CMD runs the seed before serving:

```bash
CMD ["sh", "-c", "python seed.py && exec uvicorn app:app --host 0.0.0.0 --port 8000"]
```

The API's `POST /generate` also calls `ensure_borrowers()` so the four rows are
(re)asserted on every injection.

### 1.3 API surface — real routes and methods

From `src/lms/app.py` (FastAPI, title "LMS Source API"):

| Method | Path | Purpose |
|---|---|---|
| GET | `/` | Service metadata (lists tables + endpoints) |
| GET | `/health` | Liveness + `SELECT 1` DB connectivity (`db: "ok"` / `"unreachable"`) |
| GET | `/metrics` | Prometheus text format (counters `lms_loans_generated_total{mode}`, `lms_loan_events_generated_total{mode}` + process/gc) |
| POST | `/generate?count=N&mode=clean\|dirty\|mixed` | Insert N loans + their events across the 3 tables |
| POST | `/loans/{loan_id}/disburse` | Append a `disbursement` event (optional body `{amount, occurred_at}`) |
| POST | `/payments` | Append a `payment` event (body `{loan_id, amount>0, occurred_at?}`) |

`/generate` constraints: `count` ge=1, le=100_000; `mode` must be one of
`["clean", "dirty", "mixed"]` (else HTTP 400). `mixed` is ~10% dirty
(`constants.MIXED_DIRTY_RATE = 0.10`). Response body:

```json
{"mode": "clean", "requested": 100, "loans": 100, "loan_events": 151,
 "borrowers_ensured": 4, "dirty": 0, "dirty_modes": {"null_loan_id": 0, ...}}
```

The five dirty modes (`constants.DIRTY_MODES`) map 1:1 to dbt Silver DQ rules:

| mode | defect written | dbt test tripped |
|---|---|---|
| `null_loan_id` | `loan_event.loan_id = NULL` | `not_null` + `relationships` |
| `negative_amount` | `loan.amount <= 0` | `positive_value` |
| `invalid_date` | `loan.origination_date = "not-a-date"` | `valid_date` |
| `unsupported_currency` | `loan.currency = "XYZ"` | `accepted_values` |
| `orphan_borrower_id` | `loan.borrower_id = "B-9999"` | `relationships` |

### 1.4 curl examples (against the real routes)

```bash
# Health + DB connectivity (published on the host at :8000)
curl -s http://localhost:8000/health
# → {"status":"ok","db":"ok"}

# Inject 100 clean loans
curl -s -X POST 'http://localhost:8000/generate?count=100&mode=clean'

# Inject 20 dirty loans (cycles through all five dirty modes)
curl -s -X POST 'http://localhost:8000/generate?count=20&mode=dirty'

# Record a disbursement event on an existing loan
curl -s -X POST http://localhost:8000/loans/L-xxxxxxxxxxxx/disburse \
  -H 'Content-Type: application/json' -d '{"amount": 1234.56}'

# Record a payment event
curl -s -X POST http://localhost:8000/payments \
  -H 'Content-Type: application/json' \
  -d '{"loan_id":"L-xxxxxxxxxxxx","amount":99.99}'

# Prometheus counters
curl -s http://localhost:8000/metrics | grep lms_loans_generated
```

---

## 2. Where it runs (containers, hostnames, ports, env, CDC)

Declared in `compose/docker-compose.yml`.

### `lms-postgres` (source DB)

- Image: `${POSTGRES_IMAGE:-postgres:16}`; volume `lms_pg_data`; host port `5432:5432`.
- Env defaults: `POSTGRES_USER=lms`, `POSTGRES_PASSWORD=lms`, `POSTGRES_DB=lms`
  (all overridable via `compose/.env` — `.env.example` sets `CHANGE_ME_*`).
- Healthcheck: `pg_isready -U lms`.
- **Logical-decoding settings (real values from the `command:` block):**

```bash
postgres -c wal_level=logical -c max_replication_slots=4 \
         -c max_wal_senders=4 -c shared_preload_libraries=pgoutput
```

### `lms-api` (source REST API)

- Build context `../src/lms`; host port `8000:8000`; `depends_on: lms-postgres`.
- Env: `DATABASE_URL: postgresql://${LMS_DB_USER:-lms}:${LMS_DB_PASSWORD:-lms}@lms-postgres:5432/${LMS_DB_NAME:-lms}`.
  `db.py` normalizes this to the `postgresql+psycopg2://` driver (SQLAlchemy ≥2.1
  defaults the bare dialect to psycopg v3; this service targets psycopg2).
- Internal hostname/port: `lms-api:8000`.

### How Debezium sees the WAL

Registered by the `register-connectors` one-shot from
`compose/connectors/debezium-postgres.json` (defaults in `register-connectors.sh`):

| Setting | Value |
|---|---|
| `connector.class` | `io.debezium.connector.postgresql.PostgresConnector` |
| `plugin.name` | `pgoutput` |
| `slot.name` | `lms_poc_debezium` |
| `publication.name` | `lms_poc_publication` |
| `publication.autocreate.mode` | `filtered` |
| `snapshot.mode` | `initial` |
| `heartbeat.interval.ms` | `10000` |
| `table.include.list` | `public.loan,public.loan_event,public.borrower` |
| `topic.prefix` | `lms` (topics become `lms.public.*`) |
| `database.hostname/port/user/password/dbname` | `lms-postgres` / `5432` / `lms` / `lms` / `lms` |

The Iceberg sink (`iceberg-sink.json`, registered by the same script) consumes
`SINK_TOPICS_REGEX=lms.public.*` into `ICEBERG_TABLES=bronze.loan,bronze.loan_event,bronze.borrower`.

---

## 3. The demo control panel (`demo/`)

Files: `app.py` (FastAPI harness), `static/index.html` (self-contained UI — all
CSS/JS inline, no external asset files), `requirements.txt` (`fastapi`, `uvicorn[standard]`),
`Dockerfile`, `.dockerignore` (excludes the local `.venv`).

### 3.1 How it is built and served

`demo/Dockerfile` copies `requirements.txt`, `app.py`, and `static/`, then:

```bash
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
```

In `compose/docker-compose.yml` the `demo` service has **`expose: "8000"` only —
no host port mapping**. It is reached either:

- on the compose network at `http://demo:8000`, or
- through the Traefik edge layer at **`demo.<DOMAIN>`** (router `demo` →
  `http://demo:8000`, declared in `compose/traefik/dynamic.yml` via Host-header
  routing, not container labels; `DOMAIN` defaults to `onendo.cloud`).

> ⚠️ Accuracy note: `README.md` and `docs/examples.md` say the panel is on `:8001`,
> but **`:8001` on the host is actually the `ticket-bridge`** service
> (`monitoring.yml` → `ports: ["8001:8001"]`). The demo service itself is not
> published to the host in the current compose; use the Traefik route or
> `docker compose exec demo …` to reach it directly.

### 3.2 Environment variables (all optional — unreachable ⇒ simulated)

Injected by compose (internal service names) and read by `demo/app.py`:

| Var | Compose value (default) | Purpose |
|---|---|---|
| `LMS_API_URL` | `http://lms-api:8000` | Source REST API (drives `healthy`/`dirty` injection) |
| `KAFKA_CONNECT_URL` | `http://connect:8083` | Kafka Connect / Debezium |
| `TRINO_URL` | `http://trino:8080` | Query engine |
| `METABASE_URL` | `http://metabase:3000` | BI |
| `DAGSTER_URL` | `http://dagster:3000` | Orchestration (unused in current compose) |
| `PLANE_API_URL` | `http://plane:8000/api/v1` | Ticketing API |
| `PLANE_UI_URL` | `http://plane-web:80` | Ticket link base |
| `PUSHGATEWAY_URL` | `http://pushgateway:9091` | Push `demo_failure` gauge |
| `LATENCY_SCALE` | (unset → `1.0`) | Multiplier on simulated latencies (`0.1` = fast) |
| `PLANE_API_KEY` / `PLANE_WORKSPACE` / `PLANE_PROJECT_ID` | (unset) | Needed for a **real** Plane ticket; absent ⇒ simulated ticket |

The harness probes each target at scenario start (`GET`, 1.5s timeout) and reports
`reachable` (live) vs `simulated` per system in the `start`/`done` payloads.

### 3.3 Every real endpoint

From `demo/app.py`:

| Method | Path | Purpose |
|---|---|---|
| GET | `/` | Returns `static/index.html` (the control panel UI) |
| GET | `/static/{path}` | `StaticFiles` mount on `demo/static/` — **only `index.html` exists** |
| GET | `/health` | Liveness probe (`{"status":"ok"}`) |
| POST | `/scenario/{name}?count=N&mode=clean\|dirty\|mixed` | Run a scenario, JSON result (final per-hop list + summary) |
| POST | `/scenario/{name}?stream=sse` (or `Accept: text/event-stream`) | Same, streamed as SSE events (`start` → `hop_running` → `hop_done` → `ticket` → `done`) |

Unknown `{name}` returns 404 with the valid list: `{"error": …, "scenarios": ["dirty","failure","healthy","incident"]}`.

Example calls:

```bash
# JSON result
curl -s -X POST http://demo:8000/scenario/healthy

# SSE stream (per-hop as it happens)
curl -sN -X POST 'http://demo:8000/scenario/failure?stream=sse'

# Drive a real LMS injection from the harness (healthy + clean, 1000 rows)
curl -s -X POST 'http://demo:8000/scenario/healthy?count=1000&mode=clean'
```

---

## 4. Scenarios

Defined in `demo/app.py` (`SCENARIOS`). The hop chain is
`lms → cdc → kafka → silver → gold → bi` (`HOPS`); Kafka is folded into the
`CDC → Bronze` edge.

| Scenario (exact name) | Title | Inject | Pipeline stage that reacts | Operator-visible effect |
|---|---|---|---|---|
| `healthy` | Healthy end-to-end | real `POST /generate` mode=`clean` (default count `10000`) | all hops succeed | all nodes green; no alerts; "queryable in Gold: YES" |
| `dirty` | Dirty data → DQ warning | real `POST /generate` mode=`dirty` | Silver DQ tests fail → rows quarantined | `dbt_test_failures` + `quarantine_rows_total` rise → **`DbtTestFailures`** and **`QuarantineRowsPresent`** alerts; Gold shows warning |
| `failure` | Pipeline failure (Iceberg sink) | simulated (no DB write) | Iceberg sink commit fails (MinIO 403) | pushes `demo_failure{stage="Iceberg"}=1`; Grafana Iceberg node goes red; maps to **`KafkaConnectConnectorFailed`** in the real pipeline |
| `incident` | DQ SLO breach → incident ticket | simulated (no DB write) | Gold DQ SLO breach | pushes `demo_failure{stage="Gold"}=1`; auto-opens a Plane ticket (real if `PLANE_API_KEY`/`WORKSPACE`/`PROJECT_ID` set, else simulated) |

Details worth knowing:

- `DATA_MODES = {"healthy": "clean", "dirty": "dirty"}` and `DEFAULT_INJECT_COUNT = 10000`.
  The frontend **Inject Data** panel maps `clean→healthy`, `dirty/mixed→dirty`.
- `failure`/`incident` do **not** call the LMS API — their source hop is simulated.
- `SCENARIO_FAILED_STAGE = {"failure": "Iceberg", "incident": "Gold"}`. The harness
  PUTs `demo_failure{stage="…"}=1` to the pushgateway (job `demo-scenario`); the
  Prometheus rule `pipeline_stage_health_effective` multiplies real stage health
  by `(1 - demo_failure)` so the Grafana node goes red. A `null` stage clears it.
- The `incident` scenario creates the ticket via `_create_plane_ticket`
  (`POST {PLANE_API_URL}/workspaces/{ws}/projects/{proj}/issues/`, header
  `X-API-Key`), title `[INCIDENT] gold DQ SLO breach (run <id8>)`, priority `urgent`.
- `scripts/incident-simulator.py` is a standalone equivalent that fires a
  byte-identical ticket (`[INCIDENT] {INCIDENT_TYPE}: {INCIDENT_MSG}`) for offline
  demos, using the same `PLANE_API_URL`/`PLANE_API_KEY`/`PLANE_WORKSPACE`/
  `PLANE_PROJECT_ID`/`PLANE_UI_URL` plus `INCIDENT_TYPE`/`INCIDENT_MSG`.

---

## 5. Run locally without the VM

Both components are runnable outside Docker (each has `requirements.txt` and an
`app.py` with a `__main__` block). The LMS needs a local Postgres with
`wal_level=logical` (or the compose `lms-postgres`, which is published on host `5432`).

### LMS source

```bash
cd src/lms
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
export DATABASE_URL=postgresql://lms:lms@localhost:5432/lms
python seed.py                                        # idempotent: tables + B-1001..B-1004
uvicorn app:app --host 0.0.0.0 --port 8000            # or: python app.py
```

### Demo control panel

```bash
cd demo
python3 -m venv .venv && . .venv/bin/activate          # (a .venv already exists here, gitignored)
pip install -r requirements.txt
LMS_API_URL=http://localhost:8000 uvicorn app:app --host 0.0.0.0 --port 8001
# open http://localhost:8001/  → the control panel; health: http://localhost:8001/health
```

> ⚠️ Run the demo on a port **other than 8000** when the LMS is on the same host —
> see "Port clash on 8000" below.

---

## 6. Verification

```bash
# Seeded row counts (source DB, published on host :5432)
psql postgresql://lms:lms@localhost:5432/lms \
  -c "select count(*) as borrowers from borrower;"          # → 4
psql postgresql://lms:lms@localhost:5432/lms \
  -c "select count(*) as loans from loan; select count(*) as events from loan_event;"

# API is live (host :8000)
curl -s http://localhost:8000/health                        # {"status":"ok","db":"ok"}

# Service logs
docker compose -f compose/docker-compose.yml logs -f lms-api
docker compose -f compose/docker-compose.yml logs -f lms-postgres
docker compose -f compose/docker-compose.yml logs -f connect
```

Confirm new rows reached Kafka (topics are `lms.public.loan`, `lms.public.loan_event`,
`lms.public.borrower`):

```bash
# Topic list + record counts
docker compose -f compose/docker-compose.yml exec kafka \
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka:9092 --list

# Read the tail of the loan topic to see a freshly injected row
docker compose -f compose/docker-compose.yml exec kafka \
  /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server kafka:9092 --topic lms.public.loan --max-messages 1

# Connector state (Debezium source + Iceberg sink)
curl -s http://localhost:8083/connectors/debezium-postgres/status
curl -s http://localhost:8083/connectors/iceberg-sink/status
```

---

## 7. Failure modes

**1. Seed race with the Debezium snapshot.** `register-connectors` registers the
source with `snapshot.mode=initial`, but its `depends_on` only covers
`connect`/`minio`/`polaris-setup` — it does **not** wait for `lms-api` to run
`seed.py`. If the connector's initial snapshot fires before the tables exist or
before `B-1001..B-1004` are inserted, the `borrower` snapshot is empty and the
seeded borrowers never reach Bronze. Fix: wait for `lms-api` to be healthy, then
force a fresh snapshot by re-registering the connector
(`PUT /connectors/debezium-postgres/config`) or deleting + recreating it.

**2. Missing/invalidated replication slot.** Debezium uses slot
`lms_poc_debezium`. If the slot was dropped or the Postgres data volume was reset
without clearing Kafka offsets, the connector fails to start. Check and clean up:

```sql
select slot_name, active, restart_lsn from pg_replication_slots;
```

`max_replication_slots=4` / `max_wal_senders=4` also cap the number of slots —
an exhausted pool blocks new connectors from creating their slot.

**3. Static assets 404 behind Traefik.** `demo/static/` contains **only**
`index.html` (the UI is fully inline). Any `/static/<other>` path returns 404.
If `/` itself 404s through `demo.<DOMAIN>`, confirm the image actually included
the `static/` dir (`COPY static ./static` in the Dockerfile) and that Traefik's
`demo` router is pointing at `http://demo:8000` (not a stale port).

**4. Port clash on 8000.** Both `lms-api` and `demo` bind 8000 inside their
containers; `lms-api` additionally publishes host `8000:8000`, while the demo is
`expose`-only. Running the demo locally (`uvicorn app:app --port 8000`) on the
same host as the LMS clashes — run the demo on another port (e.g. `8001`) and set
`LMS_API_URL` to the LMS host port.

Produced by: Piston · Reviewed by: Ledger
