{{ config(materialized='table', schema='silver') }}

-- Raw loan staging — the Silver boundary's upstream input (ALL rows, bad included).
--
-- PRODUCTION WIRING: reads the live Bronze CDC stream
-- (source('bronze','loan')) instead of the demo dirty_data seed.
-- The Debezium -> Iceberg sink stores `amount` as an obfuscated base64 string
-- (raw Decimal bytes); decode it here so the downstream DQ rules
-- (positive_value) and Gold aggregates can operate on real numbers.
select
    id,
    cast({{ decode_amount('amount') }} as double) as amount,
    currency,
    origination_date,
    borrower_id
from {{ source('bronze', 'loan') }}
