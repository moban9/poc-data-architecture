# dbt project — LMS POC (Silver + Gold + Quarantine)

dbt (dbt-trino) runs in-process under Dagster (see `compose/`) against Trino,
which is wired to the Polaris Iceberg REST catalog.

## Data-quality gate (quarantine) — how it works

The DQ gate is two layers:

1. **PROACTIVE (during `dbt run`)** — per-rule quarantine models
   (`models/silver/quarantine/*.sql`) isolate every row that violates a Silver
   DQ rule and append it to `lakehouse.quarantine_lms` BEFORE the clean Silver
   model builds. The clean `loan` model reads only the passing complement
   (the anti-join of the violation predicates).

2. **REACTIVE (during `dbt test`)** — the `on-run-end` hook
   (`macros/quarantine_failed_tests.sql`) re-selects any FAILING test's
   offending rows and appends them to quarantine. `schema.yml` is the assert
   gate: a failing test blocks downstream (dbt exits non-zero).

Quarantine table (`models/quarantine.sql`, doc 05 §5.4) — 11 columns:
`quarantine_id` (uuid PK), `layer`, `target_table`, `rule`, `rule_type`,
`offending_row` (JSON, stored as varchar — Iceberg has no native json type),
`error_detail`, `source` (batch/cdc), `run_id`, `quarantined_at`, `_ingested_at`.

## Layout

| Path | Purpose |
|---|---|
| `models/schema.yml` | DQ tests on `loan` / `loan_event` / `dim_borrower` / `repayment_schedule` (assert gate) |
| `models/sources.yml` | Bronze sources (raw CDC append-only) |
| `models/silver/stg_loan.sql` | Raw loan staging (reads Bronze CDC `loan`) |
| `models/silver/loan.sql` | CLEAN loan (passing-only complement) |
| `models/silver/stg_repayment_schedule.sql` | Raw repayment_schedule staging (Bronze CDC) |
| `models/silver/repayment_schedule.sql` | CLEAN repayment_schedule (one row per instalment) |
| `models/silver/quarantine/*.sql` | Per-rule quarantine models (isolate bad rows) |
| `models/quarantine.sql` | `lakehouse.quarantine_lms` DDL (11 cols) |
| `macros/quarantine_insert.sql` | Idempotent append to quarantine (anti-join) |
| `macros/quarantine_failed_tests.sql` | on-run-end test hook |
| `macros/loan_offending_row.sql` | JSON snapshot of a loan row |
| `macros/positive_value.sql` / `valid_date.sql` | Generic tests |
| `seeds/dirty_data.csv` | 5 engineered-bad rows |
| `seeds/borrowers.csv` | 4 valid borrowers (for the relationships rule) |

## Run

One command (runs seed + silver + gold, then pushes metrics to the pushgateway):

```bash
sh scripts/run-and-push-metrics.sh        # assumes dbt + dbt-trino installed
```

Or via the compose one-shot service (installs dbt-trino in a container):

```bash
docker compose up -d --force-recreate dbt
```

Manual, step by step:

```bash
cp profiles.yml.example ~/.dbt/profiles.yml   # or use dbt/profiles.yml with --profiles-dir
dbt seed --profiles-dir .                    # demo dirty_data + borrowers -> bronze (optional)
dbt run  --profiles-dir .                    # quarantine bad rows + build clean silver + gold
dbt test --profiles-dir .                    # assert gate (clean models pass; dirty rows FAIL)
```

`dbt test` is **expected** to report failures — that is the DQ gate correctly
flagging the dirty rows still flowing through `silver.loan_event` (NULL/ orphan
`loan_id`) and the `dirty_data` seed. Those failures are pushed as
`dbt_test_failures` and their offending rows land in quarantine.

## Production wiring (live CDC)

The Silver models now read the **live Bronze CDC stream** (not the demo seeds):

- `stg_loan` → `source('bronze','loan')`
- `stg_repayment_schedule` → `source('bronze','repayment_schedule')`
- `dim_borrower` → `source('bronze','borrower')`
- `loan_event` → `source('bronze','loan_event')` (unchanged passthrough)

Debezium emits `DECIMAL` columns as JSON doubles (`decimal.handling.mode=double`
in `compose/connectors/debezium-postgres.json`), so `stg_loan` and
`stg_repayment_schedule` cast the money columns (`amount`, `interest_rate`,
`monthly_installment`, `principal_due`, `interest_due`) straight to `double` —
no base64 decode.

Expected outcome (dirty demo):

- `lakehouse.quarantine_lms` holds 5 rows after `dbt run` — one per failing
  rule (`not_null__id`, `positive_value__amount`, `accepted_values__currency`,
  `valid_date__origination_date`, `relationships__borrower_id__dim_borrower`),
  each with its rule + error_detail + JSON `offending_row`.
- `silver.loan` is EMPTY (all 5 rows were bad; none pass every rule) — the
  bad row is excluded, the clean table builds without it.
- `dbt test`: schema.yml tests on the clean models PASS; the 5 `dirty_data`
  seed tests FAIL (expected detection proof) and the on-run-end hook appends
  those with `target_table='dirty_data'`.

## Notes / known gaps

- `offending_row` is stored as varchar (Iceberg has no native json type).
- The on-run-end hook requires `dbt run` (or `dbt build`) first so the
  quarantine table exists.
- Production swap is **done**: `stg_loan` -> `source('bronze','loan')`,
  `dim_borrower` -> `source('bronze','borrower')` (see "Production wiring").
  The `borrowers`/`dirty_data` seeds remain only to exercise the seed DQ tests.
- Money columns arrive as JSON doubles via `decimal.handling.mode=double`
  (Debezium), so Silver casts them straight to `double`. The old
  `macros/decode_amount.sql` base64 workaround is retired (no longer referenced).
