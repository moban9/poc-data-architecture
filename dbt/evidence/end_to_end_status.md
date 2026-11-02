# Data-quality gate + quarantine — end-to-end status

**Task:** t_98cdfdeb — wire the POC data-quality gate + quarantine end-to-end.
**Owner:** Cask (Data Engineer). **Repo:** /opt/data/poc-iac (git).

## What is wired (complete)

1. **Quarantine table — doc 05 §5.4, 11 columns**
   `models/quarantine.sql` materializes `lakehouse.quarantine_lms.quarantine_lms`
   (Polaris catalog `lakehouse`, namespace `quarantine_lms`, table
   `quarantine_lms`), via dbt-trino. `materialized='incremental'` (append mode,
   no `unique_key`) so the table is created once and **never dropped** — prior
   quarantined rows survive re-runs (append-only, per Seal's review contract).
   Columns: `quarantine_id` (uuid), `layer`, `target_table`, `rule`,
   `rule_type`, `offending_row` (JSON as varchar), `error_detail`, `source`
   (batch/cdc), `run_id`, `quarantined_at`, `_ingested_at`.

2. **Per-rule quarantine models — run BEFORE the clean Silver model**
   `models/silver/quarantine/quarantine_loan_*.sql` (5 models, one per rule that
   the dirty demo violates). Each isolates the violating rows and its post_hook
   appends them to quarantine via `macros/quarantine_insert.sql`. The clean
   `silver.loan` model (`models/silver/loan.sql`) reads only the passing
   complement (anti-join of the violation predicates) and `ref()`s the per-rule
   models for ordering.

3. **on-run-end hook — failing tests auto-append to quarantine**
   `macros/quarantine_failed_tests.sql`, wired in `dbt_project.yml` (`on-run-end`).
   Re-selects any FAILING test's offending rows and appends them to
   `lakehouse.quarantine_lms.quarantine_lms`.

4. **schema.yml tests remain the assert gate** — a failing test blocks the run
   (dbt exits non-zero); the per-rule models are the proactive isolation layer.

## Demo entities

`borrower` / `loan` / `loan_event` (the 3-entity demo). `stg_loan` reads the
`dirty_data` seed; `dim_borrower` reads the new `borrowers` seed
(B-1001..B-1004, so the relationships rule flags only B-9999). Production swap
is one line each (`stg_loan` -> `source('bronze','loan')`, `dim_borrower` ->
`source('bronze','borrower')`).

## Verification status

- **dbt installed:** dbt-core 1.12.6 + dbt-trino 1.11.0 (pip, into a venv;
  profile at `~/.dbt/profiles.yml` from `profiles.yml.example`).
- **`dbt parse`:** SUCCESS (`parse_rc=0`, evidence/dbt_validate.txt).
- **`dbt ls`:** SUCCESS — correct DAG: `quarantine` DDL -> 5 per-rule models ->
  `silver.loan` (evidence/dbt_validate.txt, dbt_compile.txt).
- **`dbt compile`:** reaches Trino, fails ONLY on
  `Connection refused (localhost:8080)` — **no Trino/Polaris is running in this
  sandbox** (evidence/dbt_compile.txt). This is the single remaining gap for a
  live `dbt seed`/`dbt run`/`dbt test`.

## Deterministic expected outcome (dirty demo)

`dbt seed` -> `dbt run` -> `dbt test` against a live Trino/Polaris should yield:

Quarantine (`lakehouse.quarantine_lms.quarantine_lms`) — **5 rows**, one per rule:

| row | target_table | rule | rule_type | offending_row (key facts) |
|---|---|---|---|---|
| 1 | loan | not_null__id | not_null | id = '' (blank) |
| 2 | loan | positive_value__amount | positive_value | amount = -500.00 |
| 3 | loan | valid_date__origination_date | valid_date | origination_date = 'not-a-date' |
| 4 | loan | accepted_values__currency | accepted_values | currency = 'XYZ' |
| 5 | loan | relationships__borrower_id__dim_borrower | relationships | borrower_id = 'B-9999' (orphan) |

Clean Silver: `silver.loan` is **empty** — all 5 rows were bad, none pass every
rule. The bad rows are isolated (in quarantine) and excluded from the clean
table. `silver.dim_borrower` = 4 rows (B-1001..B-1004).

`dbt test`: schema.yml tests on the clean `loan`/`dim_borrower` **pass**; the
`dirty_data` seed tests **fail** (4 failures via `dbt test`: positive_value,
valid_date, accepted_values, relationships).

> Nuance: `dirty_data` row 1 has a *blank* id (empty string), which the `not_null`
> test does NOT catch (it checks SQL NULL only). The per-rule anti-join catches it
> via `id is null or id = ''` — so 5 rows are quarantined, but the seed-level
> `not_null` test alone yields 4 failures, not 5. The README's "5 seed failures"
> should read "4 test failures + 1 blank-id caught by the anti-join".

## Repro (on the real VM / any host with Trino + Polaris up)

```bash
cd /opt/data/poc-iac
make deploy                       # or `cd compose && docker compose up -d`
cd dbt
cp profiles.yml.example ~/.dbt/profiles.yml   # host=trino host, catalog=lakehouse
dbt seed                          # dirty_data + borrowers -> bronze
dbt run                           # quarantine DDL + per-rule models + clean silver
dbt test                          # assert gate (silver passes, seed fails)
# evidence queries
#   select target_table, rule, rule_type, error_detail, offending_row, run_id
#   from lakehouse.quarantine_lms.quarantine_lms order by quarantined_at;
#   select * from silver.loan;    -- expect 0 rows
```

## Open items (journaled, not blocking this task)

- **5-entity reconciliation** (authoritative Bronze/Silver = customer /
  loan_application / loan / installment / payment vs the 3-entity demo) is
  Meridian's open item — already tracked under t_8ffc2bcc. This gate is built
  against the demo entities that exist today.
- **Catalog/naming blessing:** this build uses catalog `lakehouse`, namespace
  `quarantine_lms` (doc 05 / Meridian naming). The broader `bronze_lms` /
  `silver_lms` / `gold_lms` schema rename and the Trino catalog-properties file
  rename (`iceberg.properties` -> `lakehouse.properties`) are Meridian's to
  finalize.
- **Live `dbt run` proof** is blocked by the absence of Trino/Polaris/Docker in
  this build sandbox; run the repro above on the provisioned VM to capture the
  query output.
