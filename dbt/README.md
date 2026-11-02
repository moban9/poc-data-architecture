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
| `models/schema.yml` | DQ tests on `loan` / `loan_event` / `dim_borrower` (assert gate) |
| `models/sources.yml` | Bronze sources (raw CDC append-only) |
| `models/silver/stg_loan.sql` | Raw loan staging (demo: reads dirty_data seed) |
| `models/silver/loan.sql` | CLEAN loan (passing-only complement) |
| `models/silver/quarantine/*.sql` | Per-rule quarantine models (isolate bad rows) |
| `models/quarantine.sql` | `lakehouse.quarantine_lms` DDL (11 cols) |
| `macros/quarantine_insert.sql` | Idempotent append to quarantine (anti-join) |
| `macros/quarantine_failed_tests.sql` | on-run-end test hook |
| `macros/loan_offending_row.sql` | JSON snapshot of a loan row |
| `macros/positive_value.sql` / `valid_date.sql` | Generic tests |
| `seeds/dirty_data.csv` | 5 engineered-bad rows |
| `seeds/borrowers.csv` | 4 valid borrowers (for the relationships rule) |

## Run

```bash
cp profiles.yml.example ~/.dbt/profiles.yml   # fill in Trino/Polaris
dbt seed          # load dirty_data + borrowers into bronze
dbt run           # quarantine bad rows + build clean silver + create quarantine table
dbt test          # assert gate: schema.yml passes on clean data; seed tests fail 5x
```

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
- Production swap (one line each): `stg_loan` -> `source('bronze','loan')`,
  `dim_borrower` -> `source('bronze','borrower')` once the Debezium sink is live.
