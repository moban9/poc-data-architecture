{{ config(
    materialized='incremental',
    schema='quarantine_lms',
    alias='quarantine_lms'
) }}

-- ── Quarantine table: lakehouse.quarantine_lms.quarantine_lms (doc 05 §5.4) ──
-- 11-column append-only DQ quarantine, reviewed by Seal. Materialized as an
-- Iceberg table in the Polaris namespace `quarantine_lms` of catalog `lakehouse`
-- via dbt-trino.
--
-- `materialized='incremental'` (append mode, no unique_key): the FIRST `dbt run`
-- issues `create table ... as select ... where false` (empty table, correct
-- schema); later runs INSERT zero rows, so the table is NEVER dropped and prior
-- rows survive. Rows are appended only by:
--   1. per-rule quarantine models (post_hooks)  -> models/silver/quarantine/*
--   2. the on-run-end test hook                 -> macros/quarantine_failed_tests.sql
select
    cast(null as uuid)                        as quarantine_id,   -- PK (uuid). Iceberg/Trino do not enforce PKs; semantic only.
    cast(null as varchar)                     as layer,           -- bronze | silver | gold
    cast(null as varchar)                     as target_table,    -- model whose rows are quarantined (e.g. 'loan')
    cast(null as varchar)                     as rule,            -- rule id (e.g. 'positive_value', 'relationships__borrower_id__dim_borrower')
    cast(null as varchar)                     as rule_type,       -- rule family (not_null|unique|relationships|accepted_values|positive_value|valid_date)
    cast(null as varchar)                     as offending_row,   -- JSON snapshot of the offending row (Iceberg has no native json type -> varchar holding JSON)
    cast(null as varchar)                     as error_detail,    -- human-readable explanation
    cast(null as varchar)                     as source,          -- 'batch' (seed/dbt run) | 'cdc' (Debezium stream)
    cast(null as varchar)                     as run_id,          -- dbt invocation_id
    cast(null as timestamp(6) with time zone) as quarantined_at,  -- when the row was quarantined
    cast(null as timestamp(6) with time zone) as _ingested_at     -- when the row entered the lakehouse (== quarantined_at for batch)
limit 0
