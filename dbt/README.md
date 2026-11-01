# dbt project — LMS POC (Silver + Gold)

dbt (dbt-trino) runs in-process under Dagster (see `compose/`) against Trino,
which is wired to the Polaris Iceberg REST catalog.

## Layout

| Path | Purpose |
|---|---|
| `models/schema.yml` | Data-quality tests on `loan` / `loan_event` (the POC rules) |
| `models/sources.yml` | Bronze sources (raw CDC append-only) |
| `models/silver/*.sql` | Silver staging models (`loan`, `loan_event`, `dim_borrower`) |
| `models/quarantine.sql` | `lakehouse.quarantine_lms` DDL (created by `dbt run`) |
| `macros/positive_value.sql` | Generic test: amount > 0 |
| `macros/valid_date.sql` | Generic test: ISO-8601 date string |
| `macros/quarantine_insert.sql` | Append a failing row to quarantine |
| `macros/generate_schema_name.sql` | Exact `silver`/`gold`/`lakehouse` schema names |
| `seeds/dirty_data.csv` | 5 engineered-bad rows (failure scenario) |
| `seeds/properties.yml` | Tests on the seed → exactly 5 failures |

## Run

```bash
cp profiles.yml.example ~/.dbt/profiles.yml   # fill in Trino/Polaris
dbt seed     # load dirty_data into bronze
dbt run      # build silver models + create lakehouse.quarantine_lms
dbt test     # run the POC rules (expect 5 failures on dirty_data)
```

## Quarantine flow

Rows that fail a dbt test are appended to `lakehouse.quarantine_lms`
(`quarantined_at`, `source_table`, `failing_test`, `reason`, `payload`) —
append-only, never dropped, reviewed by Seal. Use `quarantine_row()`
(`macros/quarantine_insert.sql`) in a post-test hook or the Seal review
workflow to record failures.
