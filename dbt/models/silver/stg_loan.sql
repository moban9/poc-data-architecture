{{ config(materialized='table', schema='silver') }}

-- Raw loan staging — the Silver boundary's upstream input (ALL rows, bad included).
--
-- DEMO STAND-IN: reads the dirty_data seed (the engineered failure scenario).
-- Production: swap the `from` to {{ source('bronze', 'loan') }} once the
-- Debezium -> Iceberg sink is live (see sources.yml). Everything downstream —
-- the per-rule quarantine models and the clean loan model — reads from this one
-- model, so the swap is a one-line change.
select
    id,
    amount,
    currency,
    origination_date,
    borrower_id
from {{ ref('dirty_data') }}
