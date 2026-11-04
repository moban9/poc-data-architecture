# 03 — Data Pipeline (Medallion) — Operator Runbook

Manual-setup and verification for the LMS → Debezium → Kafka → Iceberg/Polaris/MinIO → Trino → dbt (Bronze/Silver/Gold/quarantine) pipeline.

Every name below is read from the repo (compose configs, connector JSON, dbt project, scripts). Secret values are referenced by env-var name only — never printed. Container names are the Compose service names; run all commands from the `compose/` directory on the VM (`cd /home/ubuntu/poc/compose`) unless noted.

---

## 1. Topology

```
LMS Postgres (lms-postgres, :5432)
   │  wal_level=logical, pgoutput, max_replication_slots=4
   ▼
Debezium Postgres source (Kafka Connect `connect`, :8083, debezium/connect:2.7.3.Final)
   │  connector `debezium-postgres`  →  topics lms.public.*
   ▼
Kafka (kafka, :9092, apache/kafka:3.8.1, KRaft single node)
   │  topics: lms.public.loan / lms.public.loan_event / lms.public.borrower + control-iceberg
   ▼
Iceberg sink (same `connect` worker, connector `iceberg-sink`)
   │  IcebergSinkConnector → Polaris REST catalog
   ▼
Polaris (polaris, :8181, apache/polaris)  ──catalog `lakehouse`──▶  MinIO (minio, :9000, adobe/s3mock)
   │  Iceberg REST catalog; metadata in polaris-postgres (:5433), data in MinIO bucket `lakehouse`
   ▼
Trino (trino, :8080)  ──catalog `lakehouse` (compose/trino/catalog/lakehouse.properties)
   │  reads Bronze, writes Silver/Gold/quarantine via dbt
   ▼
dbt (one-shot `dbt` service, onendo-dbt image) → Bronze (sources/seeds) → Silver → Gold, bad rows → quarantine_lms
```

| Hop | Compose service | Port | Image |
|---|---|---|---|
| Source DB | `lms-postgres` | 5432 | `postgres:16` |
| Source API (write path) | `lms-api` | 8000 | `../src/lms` (FastAPI) |
| Kafka Connect (source + sink) | `connect` | 8083 | `debezium/connect:2.7.3.Final` |
| Kafka broker (KRaft) | `kafka` | 9092 | `apache/kafka:3.8.1` |
| Object store | `minio` | 9000 | `adobe/s3mock:latest` |
| Catalog | `polaris` | 8181 | `apache/polaris:latest` |
| Catalog DB | `polaris-postgres` | 5433 | `postgres:16` |
| Query engine | `trino` | 8080 | `trinodb/trino:latest` |
| Transform | `dbt` (one-shot) | — | `onendo-dbt:latest` |

---

## 2. Storage layer — MinIO bucket

The "MinIO" is actually **adobe/s3mock** (`MINIO_IMAGE=adobe/s3mock:latest`). s3mock 3.x ignores the old `initialBuckets` env var, so the bucket must be created over the S3 REST API. There is **no `mc` client wired anywhere in this repo** — bucket creation lives in `compose/polaris/init-lakehouse.sh`, run by the one-shot `polaris-setup` service.

Bucket facts (from `compose/docker-compose.yml` + `compose/.env.example`):

| Thing | Value |
|---|---|
| Bucket / warehouse name | `lakehouse` (`MINIO_BUCKET`) |
| Endpoint | `http://minio:9000` (`MINIO_ENDPOINT`) |
| Region | `us-east-1` (`MINIO_REGION`) |
| Static S3 access key | `MINIO_ROOT_USER` (also `MINIO_ACCESS_KEY`) |
| Static S3 secret key | `MINIO_ROOT_PASSWORD` (also `MINIO_SECRET_KEY`) |
| Data volume | `minio_data` → `/s3mockroot` (must be `RETAIN_FILES_ON_EXIT=true`) |

The bucket is created with an idempotent S3 `PUT` (this exact call is in `init-lakehouse.sh`):

```bash
# ensure bucket exists (idempotent — 200 means already present)
curl -s -o /dev/null -w "%{http_code}\n" -X PUT "http://minio:9000/lakehouse"
# → 200
```

Polaris's catalog `storageConfigInfo` then points at this bucket (`default-base-location: s3://lakehouse`). All Iceberg data lands under `s3://lakehouse/<namespace>/<table>` (e.g. `bronze/loan`).

---

## 3. Kafka — topics and inspection

Topic creation is automatic (`KAFKA_AUTO_CREATE_TOPICS_ENABLE=true`); there is no explicit per-topic partition config, so topics use the broker default (Kafka 3.8 default `num.partitions=1`).

Topic names derive from the Debezium source config (`topic.prefix` + schema + table):

| Topic | Source |
|---|---|
| `lms.public.loan` | `public.loan` |
| `lms.public.loan_event` | `public.loan_event` |
| `lms.public.borrower` | `public.borrower` |
| `control-iceberg` | `iceberg.control.topic` (sink commit coordination) |
| `connect_configs` / `connect_offsets` / `connect_status` | Kafka Connect internal topics |

Inspect from the `kafka` container (CLI at `/opt/kafka/bin/`):

```bash
# list topics
docker compose exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list

# describe one topic (partitions, replication, offsets)
docker compose exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --describe --topic lms.public.loan

# inspect raw messages (Debezium JSON envelopes, schemas disabled)
docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic lms.public.loan --from-beginning --max-messages 2
```

---

## 4. Polaris — bootstrap

Done by `compose/polaris/init-lakehouse.sh`, executed once by the `polaris-setup` one-shot container after `polaris` + `minio` are up. The script:

1. Ensures the MinIO bucket (`PUT http://minio:9000/lakehouse`).
2. Obtains a root access token from the OAuth2 token endpoint.
3. Checks whether catalog `lakehouse` already exists (skips if so).
4. Creates the catalog via the Management API (INTERNAL, S3 storage, base `s3://lakehouse`).
5. Grants `catalog_admin` role the `TABLE_READ_DATA`, `TABLE_WRITE_DATA`, `TABLE_SET_STATISTICS` privileges so the sink and Trino can read/write.

Catalog facts:

| Thing | Value |
|---|---|
| Catalog name | `lakehouse` (`POLARIS_WAREHOUSE`) |
| Realm | `POLARIS` (`POLARIS_REALM`) |
| Root client id | `root` (`POLARIS_CLIENT_ID`) |
| Root client secret | `POLARIS_CLIENT_SECRET` — never print |
| Bootstrap principal | `POLARIS_BOOTSTRAP_CREDENTIALS` = `<realm>,<client_id>,<client_secret>` |
| OAuth2 scope | `PRINCIPAL_ROLE:ALL` |
| Storage type / base | `S3` / `s3://lakehouse`, endpoint `http://minio:9000`, `pathStyleAccess: true`, `stsUnavailable: true` |

Re-run bootstrap idempotently:

```bash
docker compose up -d --force-recreate polaris-setup
docker compose logs polaris-setup   # expect "catalog 'lakehouse' created" or "already exists — skipping"
```

Manual token fetch (equivalent of step 2, useful for debugging auth):

```bash
curl -sS -X POST "http://polaris:8181/api/catalog/v1/oauth/tokens" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=${POLARIS_CLIENT_ID:-root}" \
  --data-urlencode "client_secret=${POLARIS_CLIENT_SECRET}" \
  --data-urlencode "scope=PRINCIPAL_ROLE:ALL"
```

---

## 5. Debezium source — registration and status

Connector name is the JSON filename minus `.json`: **`debezium-postgres`** (template `compose/connectors/debezium-postgres.json`). The JSON holds `${VAR}` placeholders, rendered by `register-connectors.sh` (envsubst) and upserted with an idempotent **PUT** to `/connectors/<name>/config`.

Register via the one-shot service (this is what Compose runs on every `up -d`):

```bash
docker compose logs register-connectors   # after a full up; expect "✓ debezium-postgres registered"
```

Register manually (renders the template and PUTs it):

```bash
docker compose run --rm \
  -e CONNECT_URL=http://connect:8083 \
  -e LMS_DB_HOST=lms-postgres -e LMS_DB_PORT=5432 \
  -e LMS_DB_USER=${LMS_DB_USER} -e LMS_DB_PASSWORD=${LMS_DB_PASSWORD} -e LMS_DB_NAME=${LMS_DB_NAME} \
  -e LMS_TOPIC_PREFIX=lms \
  -e DBZ_TABLE_INCLUDE_LIST="public.loan,public.loan_event,public.borrower" \
  -e DBZ_SLOT_NAME=lms_poc_debezium -e DBZ_PUBLICATION_NAME=lms_poc_publication \
  -v "$PWD/connectors:/connectors:ro" \
  alpine/curl sh -c "apk add --no-cache bash gettext jq >/dev/null && bash /connectors/register-connectors.sh debezium-postgres"
```

Underlying raw curl (after `${VAR}` substitution — note **PUT**, not POST, for idempotent upsert):

```bash
curl -fsS -X PUT \
  -H 'Content-Type: application/json' \
  --data-binary @connectors/debezium-postgres.json \
  "http://connect:8083/connectors/debezium-postgres/config"
```

Key source config (from `debezium-postgres.json`):

| Setting | Value |
|---|---|
| `connector.class` | `io.debezium.connector.postgresql.PostgresConnector` |
| `plugin.name` | `pgoutput` |
| `topic.prefix` | `lms` |
| `table.include.list` | `public.loan,public.loan_event,public.borrower` |
| `slot.name` / `publication.name` | `lms_poc_debezium` / `lms_poc_publication` |
| `publication.autocreate.mode` | `filtered` |
| `snapshot.mode` | `initial` |
| `key/value.converter` | `JsonConverter`, `schemas.enable=false` |

Check status (connector + task state):

```bash
curl -s http://connect:8083/connectors/debezium-postgres/status
```

```json
{ "name": "debezium-postgres",
  "connector": { "state": "RUNNING", "worker_id": "…" },
  "tasks": [ { "id": 0, "state": "RUNNING", "worker_id": "…" } ] }
```

**What `RUNNING` proves:** the connector config was accepted, a task was assigned to a worker, and the task is actively snapshotting (initial) and/or streaming the WAL through the `pgoutput` plugin. It does *not* by itself prove rows are landing downstream — that is verified in §6–§7. If `state` is `FAILED`, read the task trace:

```bash
curl -s http://connect:8083/connectors/debezium-postgres/status | jq '.tasks[0].trace'
```

---

## 6. Iceberg sink — config and table creation

Connector name: **`iceberg-sink`** (template `compose/connectors/iceberg-sink.json`). Registers the same way as §5.

Key sink config:

| Setting | Value |
|---|---|
| `connector.class` | `org.apache.iceberg.connect.IcebergSinkConnector` |
| `topics.regex` | `lms.public.*` |
| `iceberg.tables` | `bronze.loan,bronze.loan_event,bronze.borrower` |
| `iceberg.tables.route-field` | `_cdc.target` |
| route-regex per table | `bronze\.loan` / `bronze\.loan_event` / `bronze\.borrower` |
| `iceberg.tables.auto-create-enabled` | `true` |
| `iceberg.tables.evolve-schema-enabled` | `true` |
| `iceberg.tables.schema-force-optional` | `true` |
| auto-create props | `format-version: 2`, `write.format.default: parquet` |
| `iceberg.control.topic` | `control-iceberg` |
| `iceberg.catalog.type` | `rest` |
| `iceberg.catalog.uri` | `http://polaris:8181/api/catalog` |
| `iceberg.catalog.warehouse` | `lakehouse` (Polaris **catalog name**, not an S3 URI — the bucket comes from Polaris `storageConfigInfo`) |
| `iceberg.catalog.credential` | `${POLARIS_CREDENTIAL}` = `root:${POLARIS_CLIENT_SECRET}` |
| `iceberg.catalog.scope` | `PRINCIPAL_ROLE:ALL` |
| `iceberg.catalog.io-impl` | `org.apache.iceberg.aws.s3.S3FileIO` |
| `iceberg.catalog.s3.*` | endpoint/keys/region/path-style → MinIO |
| `transforms` | `unwrap` = `org.apache.iceberg.connect.transforms.DebeziumTransform`, `cdc.target.pattern=bronze.{table}` |

The sink plugin jars are **not** in the image — assemble them once into `compose/connect-plugins/`:

```bash
scripts/fetch-iceberg-jars.sh
docker compose -f docker-compose.yml -f monitoring.yml -f traefik.yml up -d connect
```

Table creation expectations: on first CDC messages, `auto-create-enabled` creates `lakehouse.bronze.loan`, `lakehouse.bronze.loan_event`, `lakehouse.bronze.borrower` as Iceberg format-v2 Parquet tables. Known quirk (documented in `dbt/README.md` + `dbt/macros/decode_amount.sql`): the sink stores `loan.amount` (Postgres `NUMERIC(18,2)`) as an **obfuscated base64 string** of the raw decimal bytes — dbt's `stg_loan` decodes it back to numeric via the `decode_amount` macro.

Verify tables landed (Polaris + Trino are the authoritative checks):

```bash
# via Trino (see §7)
docker compose exec trino trino --execute "SHOW TABLES IN lakehouse.bronze"

# via Polaris Management API (list namespaces/tables in catalog lakehouse)
curl -s -H "Authorization: Bearer ${POLARIS_TOKEN}" -H "Polaris-Realm: POLARIS" \
  "http://polaris:8181/api/catalog/v1/lakehouse/namespaces/bronze/tables" | jq '.identifiers[].name'
```

(There is no `mc` client in the repo; raw objects live under `s3://lakehouse/bronze/…` in s3mock and can be listed through the S3 REST API if needed.)

---

## 7. Trino — catalog and verification queries

Catalog properties file: **`compose/trino/catalog/lakehouse.properties`**. The Trino catalog name is the file basename → `lakehouse` (which is why the file is not `iceberg.properties`; see `compose/trino/catalog/README.md`). `connector.name` is still `iceberg`.

Key properties (env-parameterized via `${ENV:...}`):

| Property | Value |
|---|---|
| `connector.name` | `iceberg` |
| `iceberg.catalog.type` | `rest` |
| `iceberg.rest-catalog.uri` | `${ENV:POLARIS_URI}` |
| `iceberg.rest-catalog.warehouse` | `${ENV:POLARIS_WAREHOUSE}` = `lakehouse` |
| `iceberg.rest-catalog.security` | `OAUTH2` |
| `iceberg.rest-catalog.oauth2.credential` | `${ENV:POLARIS_CLIENT_ID}:${ENV:POLARIS_CLIENT_SECRET}` |
| `iceberg.rest-catalog.oauth2.scope` | `PRINCIPAL_ROLE:ALL` |
| `iceberg.rest-catalog.http-headers` | `Polaris-Realm: ${ENV:POLARIS_REALM}` |
| `iceberg.rest-catalog.vended-credentials-enabled` | `false` (static S3 keys below are used) |
| `fs.s3.enabled` / `s3.endpoint` / `s3.aws-access-key` / `s3.aws-secret-key` / `s3.path-style-access` / `s3.region` | native S3 → MinIO |

Real schema/table names (from `dbt/models/sources.yml`, `dbt_project.yml`, model files):

| Schema | Tables |
|---|---|
| `bronze` | `loan`, `loan_event`, `borrower` (CDC append-only) + seeds `dirty_data`, `borrowers` |
| `silver` | `stg_loan`, `loan`, `loan_event`, `dim_borrower` (+ per-rule `quarantine_loan_*` models) |
| `gold` | `loan_portfolio`, `loan_origination_daily`, `loan_event_summary` |
| `quarantine_lms` | `quarantine_lms` |

Verification SELECTs (CLI documented in-repo; if the CLI hits the known JMX javaagent port conflict, use the HTTP API helper `dbt/scripts/trino_query.py` instead):

```bash
docker compose exec trino trino --execute "SHOW SCHEMAS IN lakehouse"
docker compose exec trino trino --execute "SHOW TABLES IN lakehouse.bronze"
docker compose exec trino trino --execute "SELECT count(*) FROM lakehouse.bronze.loan"
docker compose exec trino trino --execute "SELECT * FROM lakehouse.bronze.loan LIMIT 5"
docker compose exec trino trino --execute "SELECT currency, count(*) FROM lakehouse.gold.loan_portfolio GROUP BY currency"
```

HTTP API equivalent (stdlib-only, no CLI):

```bash
python3 dbt/scripts/trino_query.py "SELECT count(*) FROM lakehouse.bronze.loan" --host trino
# → [[ <row count> ]]
```

---

## 8. dbt — project, models, run commands, quarantine

Project: `dbt/dbt_project.yml` (name `lms_poc`, profile `lms_poc`). Profile `dbt/profiles.yml` target **`dev`**:

| Profile key | Value |
|---|---|
| `type` | `trino` |
| `method` | `none` (POC posture) |
| `host` | `{{ env_var('DBT_TRINO_HOST', 'trino') }}` (port 8080) |
| `user` | `meridian` |
| `catalog` | `lakehouse` |
| `schema` | `bronze` (default for seeds/unscoped models) |

Models by layer (grain/purpose, one line each):

- **Bronze** — not dbt models; read via `source('bronze', …)` from `models/sources.yml` (`loan`, `loan_event`, `borrower`). Seeds (`dirty_data`, `borrowers`) also land in `bronze`.
- **`stg_loan`** (silver) — raw loan staging from Bronze `loan`; decodes the base64 `amount` to numeric via `decode_amount`.
- **`dim_borrower`** (silver) — borrower dimension, one row per borrower (`id`, `full_name`) from Bronze `borrower`.
- **`loan`** (silver) — CLEAN loan table: the passing-only complement of `stg_loan` (anti-join of the 5 DQ predicates).
- **`loan_event`** (silver) — passthrough of Bronze `loan_event` (`id`, `loan_id`, `event_type`, `occurred_at`).
- **`quarantine_loan_*`** (silver, 5 models) — per-rule isolation; each `post_hook` appends violating rows to quarantine BEFORE the clean `loan` builds.
- **`loan_portfolio`** (gold) — per-currency portfolio roll-up (`currency`, `loan_count`, `total_amount`, `avg_amount`).
- **`loan_origination_daily`** (gold) — daily origination volume (`origination_date`, `loan_count`, `total_amount`).
- **`loan_event_summary`** (gold) — event activity by type (`event_type`, `event_count`, `distinct_loans`).
- **`quarantine`** — `lakehouse.quarantine_lms.quarantine_lms`, 11-column append-only DQ table (uuid PK, layer, target_table, rule, rule_type, offending_row, error_detail, source, run_id, quarantined_at, _ingested_at).

Exact run commands (from `dbt/README.md` and the Compose service):

```bash
# one command (seed + run + test, then push metrics to the pushgateway)
sh dbt/scripts/run-and-push-metrics.sh

# or via the compose one-shot service
docker compose up -d --force-recreate dbt

# manual, step by step (from dbt/)
cp profiles.yml.example ~/.dbt/profiles.yml   # or use dbt/profiles.yml with --profiles-dir .
dbt seed  --profiles-dir .                    # dirty_data + borrowers → bronze
dbt run   --profiles-dir .                    # quarantine DDL + per-rule models + clean silver + gold
dbt test  --profiles-dir .                    # assert gate (schema.yml tests)
```

Seeds: `dbt/seeds/dirty_data.csv` (5 engineered-bad rows) and `dbt/seeds/borrowers.csv` (B-1001…B-1004, valid borrowers backing `dim_borrower`).

**How quarantine captures bad rows** (two layers, per `dbt/README.md`):

1. **Proactive** (`dbt run`): each `models/silver/quarantine/quarantine_loan_*.sql` model isolates rows violating one DQ rule and its `post_hook` calls `quarantine_insert` (idempotent anti-join on `target_table`/`rule`/`offending_row`), appending to `lakehouse.quarantine_lms`. The clean `silver.loan` then reads only the passing complement.
2. **Reactive** (`dbt test`): the `on-run-end` hook (`macros/quarantine_failed_tests.sql`) re-selects any FAILING test's offending rows and appends them to quarantine. `schema.yml` remains the assert gate — a failing test still exits non-zero.

Expected dirty-demo outcome: 5 rows in `quarantine_lms` (one per rule), `silver.loan` empty, `silver.dim_borrower` = 4 rows.

---

## 9. End-to-end verification checklist (ordered)

1. **Stack up** — `make deploy` (or `cd compose && docker compose -f docker-compose.yml -f monitoring.yml -f traefik.yml up -d --pull always`). Expect all services `Up`/`exited (0)` for the one-shots (`polaris-setup`, `register-connectors`, `dbt`).
2. **Polaris catalog exists** — `docker compose logs polaris-setup` shows `catalog 'lakehouse' created` (or `already exists`).
3. **MinIO bucket exists** — `curl -s -o /dev/null -w "%{http_code}\n" -X PUT http://minio:9000/lakehouse` → `200`.
4. **Connectors registered & RUNNING** — `curl -s http://connect:8083/connectors/debezium-postgres/status` and `…/iceberg-sink/status` both show `connector.state: RUNNING`, `tasks[].state: RUNNING`.
5. **Kafka topics exist** — `docker compose exec kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list` lists `lms.public.loan`, `lms.public.loan_event`, `lms.public.borrower`.
6. **Inject source data** — `curl -X POST "http://localhost:8000/generate?count=100&mode=clean"` (via `lms-api`), or the demo panel's healthy/dirty scenario.
7. **Messages flowing** — `kafka-console-consumer` on `lms.public.loan` shows Debezium JSON envelopes.
8. **Bronze tables created** — `docker compose exec trino trino --execute "SHOW TABLES IN lakehouse.bronze"` lists `loan`, `loan_event`, `borrower`; `SELECT count(*) FROM lakehouse.bronze.loan` > 0.
9. **dbt run succeeds** — `sh dbt/scripts/run-and-push-metrics.sh` exits 0 and prints `dbt_test_failures=N dbt_tests_total=N quarantine_rows_total=N`.
10. **Silver/Gold tables exist** — `SHOW TABLES IN lakehouse.silver` (`loan`, `loan_event`, `dim_borrower`, `stg_loan`) and `lakehouse.gold` (`loan_portfolio`, `loan_origination_daily`, `loan_event_summary`).
11. **Quarantine populated** — `SELECT count(*) FROM lakehouse.quarantine_lms.quarantine_lms` reflects quarantined rows (5 in the dirty demo).
12. **Metrics pushed** — `curl -s http://pushgateway:9091/metrics | grep -E 'dbt_run_success|quarantine_rows_total'` shows non-empty values.

---

## 10. Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| **Connector retry loop** — `tasks[].state` flaps or `FAILED` with repeated restarts | Bad source creds / WAL slot gone / unreachable DB; Connect retries until `errors.tolerance` exhausted | `curl -s …/status | jq '.tasks[0].trace'`; check `docker compose logs connect`; re-create the slot (`SELECT pg_create_logical_replication_slot('lms_poc_debezium','pgoutput')`) or re-PUT the connector config |
| **Schema drift** — new/renamed source columns don't appear in Bronze | Sink `evolve-schema-enabled=true` handles additive drift; drop/rename needs a fresh table | Confirm `iceberg.tables.evolve-schema-enabled: "true"` in `iceberg-sink.json`; for breaking changes recreate the Bronze table and re-snapshot |
| **Catalog 401** — Polaris returns 401 on token/token-bearing calls | Realm/client-id/secret mismatch (`POLARIS_REALM`, `POLARIS_CLIENT_ID`, `POLARIS_CLIENT_SECRET`) or `Polaris-Realm` header missing | Re-check `POLARIS_BOOTSTRAP_CREDENTIALS` format `<realm>,<client_id>,<client_secret>` and the `Polaris-Realm` header on every Management call; ensure Trino's `http-headers` matches |
| **Trino cannot see table** — `SHOW TABLES` empty or `Table not found` | Sink hasn't created it yet (no CDC messages), catalog/warehouse mismatch, or sink `auto-create` off | Confirm source data flowed (§9.6–7); confirm `iceberg.catalog.warehouse= lakehouse` and the catalog `default-base-location` bucket is `lakehouse`; confirm `iceberg.tables.auto-create-enabled: "true"` |
| **dbt test failures** | Expected on dirty data (that is the DQ gate working); unexpected on clean data indicates a regression or a rule/config mismatch | `dbt test` lists failing tests; offending rows land in `quarantine_lms` via the on-run-end hook; check `schema.yml` rules vs `constants.DIRTY_MODES` and the sink's base64 `amount` decoding (`decode_amount`) |

---

Produced by: Meridian + Cask · Reviewed by: Ledger
