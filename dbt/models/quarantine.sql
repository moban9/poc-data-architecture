{{ config(
    materialized='table',
    schema='lakehouse'
) }}

-- ── Quarantine table: lakehouse.quarantine_lms ───────────────────────────
-- Rows that fail a dbt test are appended here for review by Seal.
-- Append-only, never dropped. Each row records the failing rule + why.
--
-- Materialized as an empty table with the correct schema: `dbt run` issues
-- `create table ... as select ... where false` against Trino, which creates an
-- Iceberg table in the Polaris catalog. Append via macros/quarantine_insert.sql.
select
    cast(null as timestamp(3) with time zone) as quarantined_at,  -- when the row was quarantined
    cast(null as varchar)                     as source_table,   -- e.g. 'loan', 'loan_event'
    cast(null as varchar)                     as failing_test,   -- e.g. 'positive_value', 'relationships__borrower_id__dim_borrower'
    cast(null as varchar)                     as reason,         -- human-readable explanation
    cast(null as varchar)                     as payload         -- JSON snapshot of the offending row
where false
