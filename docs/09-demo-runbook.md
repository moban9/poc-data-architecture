# Demo Runbook — Data Pipeline POC

Live stack on `lms-poc-vm` (GCP `asia-southeast2`). This runbook documents the demo scenarios, the commands to run them, and the expected results. Run a scenario by `POST`ing to the demo control panel; every result reflects the REAL pipeline (no simulated/hardcoded outcomes).

## Architecture (end-to-end)

```
LMS Postgres ──Debezium CDC──▶ Kafka ──iceberg-sink──▶ MinIO/Polaris ──▶ Trino
   (source)                                                          (query engine)
                                                                        │
        Metabase BI ◀── gold ◀── silver ◀── bronze ◀── dbt (Dagster, */15)
```

| Stage | What it holds | Verify |
|---|---|---|
| LMS Postgres | source loans/events/schedules | `psql` in `lms-monitoring-lms-postgres-1` |
| Bronze (Iceberg) | raw CDC copies | Trino `lakehouse.bronze.*` |
| Silver | dbt-clean + quarantine | Trino `lakehouse.silver.*` |
| Gold | portfolio / NPL / snapshot | Trino `lakehouse.gold.*` |
| Metabase | 2 dashboards — 29 business + 8 DQ cards | https://bi.onendo.cloud |
| Grafana | topology + connector status | https://grafana.onendo.cloud |
| Plane | incident tickets | https://plane.onendo.cloud/poc/ |

## URLs & credentials

- **Demo panel:** https://demo.onendo.cloud (run scenarios here)
- **BI:** https://bi.onendo.cloud/dashboard/3 (business) · https://bi.onendo.cloud/dashboard/<DQ id> (data quality — id printed by `provision_metabase.py`) · login `randy.joeandy@gmail.com` / `metabase89`
- **Grafana:** https://grafana.onendo.cloud · `admin` / (see `compose/.env`)
- **Plane:** https://plane.onendo.cloud/god-mode/ · `randy@onendo.cloud` / `Poc-cefc14ab8e1bf58609f9e0ee-Aa1!`
- **Trino:** `trino:8080` (no auth, any `X-Trino-User`)

## Scenarios

All scenarios: `POST https://demo.onendo.cloud/scenario/{name}` (SSE stream if the client sends `Accept: text/event-stream`, else JSON).

### Scenario A — Data injection (clean)

Inject a clean loan batch and watch it flow end-to-end.

- **Run:** `POST /scenario/npl-book` (realistic NPL loan book) — or `POST /generate?count=10000&mode=clean` on the LMS.
- **Expected:** `10000` loans + `~21000` events land in the source, flow through CDC in ~2 min, and appear in bronze (`bronze.loan` +10000, `bronze.loan_event` +~21000). Silver holds the clean subset; gold aggregates update on the next dbt tick (≤15 min).
- **Verify:** Trino `SELECT count(*) FROM lakehouse.bronze.loan` increases by the injected amount; BI portfolio cards show the new book.

### Scenario B — Data quality (quarantine)

Inject dirty rows and confirm they are quarantined, not silently dropped.

- **Run:** `POST /generate?count=10000&mode=mixed` (5 dirty modes: null loan_id, negative amount, bad date, bad currency, orphan borrower).
- **Expected:** ~1000 dirty rows (198 each) fail dbt tests and land in `quarantine_lms` / the DQ log; silver excludes them.
- **Verify:** BI **Data Quality** dashboard shows the quarantined-row count + rule breakdown (null_loan_id, negative_amount, invalid_date, unsupported_currency, orphan_borrower_id).

### Scenario C — Pipeline failure (real kill)

Kill a real process and confirm monitoring reflects it.

- **Run:** `POST /scenario/failure`
- **Expected:** the kill-switch `docker stop`s the MinIO object store → the iceberg-sink stops writing → Grafana topology **Iceberg node turns RED** (`probe_success{minio}=0`), no `simulated` fallback — the demo surfaces the real error.
- **Recover:** `POST /scenario/failure` has a reversible counterpart — restart MinIO (or `POST` the start endpoint) and the sink recovers.
- **Verify:** Grafana topology node is RED (a circle, not `1`/`0`); `docker inspect lms-monitoring-minio-1` shows it stopped.

### Scenario D — DQ incident → auto-ticket

Breach the DQ SLO and confirm a real ticket is created.

- **Run:** `POST /scenario/incident`
- **Expected:** ~2000 dirty rows injected → dbt run+test → DQ genuinely breaches (`dbt_test_failures > 0`) → a **real Plane ticket** is auto-created with `simulated: false` (a concrete issue id + URL).
- **Verify:** BI DQ dashboard shows the breach; Plane project issue list (https://plane.onendo.cloud/poc/) shows the new ticket.

## Layer counts (fresh state = 0, then grows as you inject)

```sql
SELECT count(*) FROM lakehouse.bronze.loan;
SELECT count(*) FROM lakehouse.bronze.loan_event;
SELECT count(*) FROM lakehouse.bronze.repayment_schedule;
SELECT count(*) FROM lakehouse.silver.loan;
SELECT count(*) FROM lakehouse.gold.loan_portfolio_summary;
SELECT count(distinct as_of_date) FROM lakehouse.gold.loan_delinquency_snapshot;
```

## Grafana status convention

UP/RUNNING renders as a **green circle**; DOWN/FAILED renders as a **red circle** — never `1`/`0`. Applies to the topology nodes and the Kafka connector status.
