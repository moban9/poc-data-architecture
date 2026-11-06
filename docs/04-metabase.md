# 04 — Metabase (BI)

Operator runbook for the Metabase service in the POC stack. Everything here is
grounded in the repo as it exists; where the repo has no configuration for a
step, that is stated explicitly rather than invented.

## 1. What Metabase is for, and what it must point at

Metabase is the BI/Serve layer: it answers human queries against the Gold marts
and renders the KPI dashboard that the demo scenarios light up (`HOPS` → `bi`:
"Trino query → Metabase"). It does **not** talk to Postgres, Kafka, MinIO, or
Polaris directly — its only data source is Trino.

- **Internal hostname:port** — `trino:8080` (the Trino compose service on the
  shared `lms-poc` network; Trino listens on 8080, see
  `compose/docker-compose.yml`).
- **Catalog** — `lakehouse` (the Trino catalog name is the basename of
  `compose/trino/catalog/lakehouse.properties`, which wires the Iceberg REST
  connector to Polaris).
- **Schemas** — `bronze`, `silver`, `gold`, and the default `lakehouse` schema.
  Dashboards should query the **Gold** marts under `lakehouse.gold.*`.
- **Auth** — Trino is **unauthenticated** in this POC (`dbt/profiles.yml`:
  `method: none`). Metabase connects with any username and **no password**. The
  OAuth2 in `lakehouse.properties` is *Trino→Polaris* auth, transparent to
  Metabase.

The intended BI role is stated in `docs/architecture.md` (Serve stage:
`Gold → Trino → Metabase`) and the DQ flow (`bad data → quarantine_lms`, never
into a KPI).

## 2. Service

From `compose/docker-compose.yml` (the `metabase` service):

- **Image**: `${METABASE_IMAGE:-metabase/metabase:latest}` — pinned in
  `compose/.env.example` as `METABASE_IMAGE=metabase/metabase:latest`.
- **Environment variables actually set** (only these four; there are **no**
  `MB_ADMIN_*` or other `MB_*`/`METABASE_*` vars in `.env.example` — the admin
  account is created in the UI, not via env):
  - `MB_JETTY_PORT=3000`
  - `MB_DB_FILE=/metabase-data/metabase.db` (application DB is an embedded H2
    file inside the named volume)
  - `JAVA_TOOL_OPTIONS=-Xmx1280m`
  - `MB_ENABLE_QUERY_CACHING=false` (disabled so freshly injected demo data
    shows up immediately; Trino is local so load is negligible)
- **Volume**: `metabase_data:/metabase-data` (the only volume; holds the H2 app
  DB with all users, questions, dashboards, and the saved Trino connection).
- **Port**: published `8085:3000` — reachable on the host at
  `http://localhost:8085` (no host-side TLS; the public edge is Traefik).
- **Traefik hostname**: `bi.<DOMAIN>` (default `bi.onendo.cloud`). Routed by the
  file provider in `compose/traefik/dynamic.yml` — router `bi` → service
  `metabase` → `http://metabase:3000`. There are **no** Traefik labels on the
  service itself (routing is static config, not the docker provider).
- **Resources**: `mem_limit: 2g`, `cpus: 0.5`.
- **depends_on**: `trino` (started only — no health condition, and **no
  healthcheck** is defined for Metabase).
- **First-boot behaviour / timing**: on an empty H2 DB, Metabase boots its JVM,
  migrates the schema, and serves the setup wizard. No healthcheck means
  `docker compose up -d` returns before it is ready. Allow ~30–60 s (longer on
  very first run due to schema migration). Readiness signal — watch the log for
  the initialisation-complete line:

  ```bash
  docker compose logs -f metabase | grep -i "initialization complete"
  ```

## 3. First-run setup

1. Open the UI: `http://localhost:8085` (host) or `https://bi.onendo.cloud`
   (edge). The setup wizard appears.
2. Create the admin user (name/email/password of your choice — not set by env).
3. Skip the sample database (X2A / "I'll add my data later").
4. **Admin → Databases → Add database → Database type: Trino.** Field values:

   | Field | Value | Notes |
   |---|---|---|
   | Display name | `Lakehouse` | arbitrary label |
   | Host | `trino-metabase-gw` | **the header gateway, not `trino`** — see §9 and [08](08-trino-metabase-auth.md); once the gateway is applied, `trino` 401s every Metabase query because Metabase sends `X-Presto-User` |
   | Port | `8080` | Trino HTTP port |
   | Username | `meridian` (or anything) | Trino is unauthenticated (`method: none`) |
   | Password | *(empty)* | no auth in POC |
   | SSL | off | plain HTTP |
   | Catalog | `lakehouse` | Trino catalog name |
   | Schema | `gold` | default namespace (models use fully-qualified names anyway) |

5. **Save.** Metabase syncs the schema; `lakehouse.gold.loan_portfolio_summary`,
   `loan_event_daily`, `loan_delinquency` (plus `silver.*`, `bronze.*`,
   `lakehouse.quarantine_lms`) should appear under the Lakehouse database.

> The connection is **not** configured in code anywhere in the repo — there is
> no env var, init script, or compose-side setup that provisions the Metabase
> Trino database. The UI steps above are the authoritative (and only) path.

## 4. Verification query

From the Metabase SQL editor (or `docker compose exec trino trino`), run a real
query against a real Gold table:

```sql
SELECT loan_status, loan_type, loan_count, total_principal, outstanding_balance
FROM lakehouse.gold.loan_portfolio_summary
ORDER BY loan_status, loan_type;
```

Expected shape: one row per (`loan_status`, `loan_type`) combination —
`loan_status` ∈ `originated`/`disbursed`/`repaying`, `loan_type` ∈
`micro`/`small`/`medium`/`large` — with numeric `loan_count`,
`total_principal`, `outstanding_balance`. If the table is missing, the dbt Gold
run has not completed (see §8).

Direct Trino cross-check (same tables, bypassing Metabase):

```bash
cd compose
docker compose exec trino trino --execute "SELECT * FROM lakehouse.gold.loan_portfolio_summary"
```

## 5. Building the dashboard

Use the Gold marts (real names from `dbt/models/gold/`). Suggested cards mapped
to the demo scenario story (`demo/app.py`):

| Card | Type | Source (table) | Metric |
|---|---|---|---|
| Total loan book | KPI / single number | `loan_portfolio_summary` | `SUM(total_principal)` |
| Loans by status | Bar | `loan_portfolio_summary` | `loan_count` grouped by `loan_status` |
| Daily originations | Line / area (time) | `loan_event_daily` | `origination_count` over `event_date` |
| Event activity | Bar | `loan_event_daily` | `disbursement_count` / `payment_count` over `event_date` |
| **NPL rate** | KPI / single number | `loan_delinquency` | `npl_rate` (portfolio-level) |
| **Delinquency buckets** | Table | `loan_delinquency` | `loan_count`, `outstanding_balance`, `share_of_book` by `delinquency_bucket` |
| Data Quality — quarantined rows | Table / count | `lakehouse.quarantine_lms` | rows grouped by `rule` (DQ panel) |

The two NPL cards are reproduced as paste-ready native queries in `bi/metabase/`
(`npl_rate_kpi.sql`, `delinquency_buckets.sql`); see `bi/metabase/README.md` for
the exact paste location (New question → Native query → Lakehouse → Trino) and
card/formatting settings.

Filters: a date-range filter on `event_date` for the daily-originations and
event-activity cards. The NPL and delinquency cards are portfolio-level (no
filter). The DQ card drives the "dirty" / "incident" scenarios: `quarantine_lms`
only fills when dbt isolates bad rows, so the panel stays empty on a clean run
and lights up on dirty runs (the "DQ banner" the scenario narrates).

## 6. Persistence + config-as-data

- All Metabase state (admin user, the saved Trino connection, questions,
  dashboards, collections) lives in the H2 file at
  `/metabase-data/metabase.db`, backed by the named volume
  `metabase_data` (actual Docker name `lms-poc_metabase_data`, since the compose
  project is `name: lms-poc`).
- **Back up**: the H2 app DB file is the entire configuration. Back up the
  volume (stop Metabase first for a consistent copy):

  ```bash
  docker compose stop metabase
  docker run --rm -v lms-poc_metabase_data:/data -v "$PWD:/backup" \
    alpine tar czf /backup/metabase-data.tgz -C /data .
  docker compose start metabase
  ```

- **Reset (DESTRUCTIVE)**: deleting the app DB wipes every user, the database
  connection, and all dashboards — irreversible unless you have a backup. Reset
  only when re-running the whole first-run setup from scratch:

  ```bash
  docker compose down -v metabase   # ⚠️ removes the metabase_data volume
  # or, directly: docker volume rm lms-poc_metabase_data
  ```

  After reset, §3 must be repeated (admin + Trino connection + dashboard).

## 7. API automation

**Not automated in this repo — do it in the UI.** `scripts/` contains no
Metabase automation, and `demo/app.py` only references `METABASE_URL`
(`http://localhost:8085`) as a reachability probe for its topology panel; it
does not call the Metabase API to create databases/questions/dashboards. There
are no Metabase API endpoints or setup scripts in the repo, so the steps in §3
and §5 are manual.

## 8. Failure modes

- **Cannot reach Trino (network/DNS)**: the Host must be `trino` (compose
  service name), not `localhost` — `localhost` inside the Metabase container is
  Metabase itself. Confirm Metabase and Trino share the `lms-poc` network and
  that Trino is up:

  ```bash
  docker compose ps trino metabase
  docker compose exec metabase sh -c 'wget -qO- http://trino:8080/v1/info || echo UNREACHABLE'
  ```

  Trino's own healthcheck hits `http://localhost:8080/v1/info` — a
  non-healthy Trino means the engine isn't ready, and `depends_on` only ordered
  startup, it did not wait for health.
- **Catalog not visible**: `lakehouse` catalog is created by the one-shot
  `polaris-setup` service (`init-lakehouse.sh`) and Trino waits on
  `polaris-setup` completing. Check the catalog and schemas:

  ```bash
  docker compose exec trino trino --execute "SHOW CATALOGS"
  docker compose exec trino trino --execute "SHOW SCHEMAS IN lakehouse"
  ```

  If `gold` is missing the dbt one-shot hasn't succeeded (it runs after Trino is
  healthy): re-run with `docker compose up -d --force-recreate dbt`.
- **Wrong timezone / date column**: `event_date` is a DATE
  (`loan_event_daily`), not a timestamp — group by it as a date. Trino's
  JVM has no `TZ` set in compose, so times are UTC. If report dates look off by
  a day, set the report timezone in Admin → Settings → Localization (Metabase
  defaults to the JVM UTC). `loan_event.occurred_at` is the only true timestamp.
- **OOM on 8 GB**: Metabase is capped at `mem_limit: 2g` with `-Xmx1280m`. On a
  16 GB host this is comfortable, but alongside Trino (2 g) and Kafka (1.5 g)
  on a smaller box the JVM can hit its cap on wide tables or large exports.
  Mitigations: `MB_ENABLE_QUERY_CACHING` is already `false`; avoid
  `SELECT *` on `bronze.*`; raise `-Xmx`/`mem_limit` only after confirming the
  host has headroom (`docker stats`).

## 9. Trino connection auth (`presto-jdbc` vs Trino 484)

Metabase v0.65's only Trino engine is `presto-jdbc` (`io.prestosql.jdbc`), which
sends `X-Presto-User`; Trino 484 accepts only `X-Trino-User`. A connection saved
straight to `trino:8080` therefore looks healthy but 401s on every query.

The fix is the `trino-metabase-gw` nginx sidecar
(`compose/docker-compose.metabase-trino-gw.yml`), which copies `X-Presto-User`
into `X-Trino-User`; Trino stays unauthenticated, so dbt/Dagster are untouched.
**Leave the Metabase Password field empty** — the Presto JDBC driver refuses
`user`+`password` unless SSL is enabled
(`Authentication using username/password requires SSL to be enabled`), so a
password on this connection can never work over plain HTTP.

Apply, verify, cost and rollback: [08 — Metabase → Trino authentication](08-trino-metabase-auth.md).

---

Produced by: Prism · Reviewed by: Ledger
