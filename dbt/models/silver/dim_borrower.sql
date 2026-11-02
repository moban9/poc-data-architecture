{{ config(materialized='table', schema='silver') }}

-- Borrower dimension. One row per borrower id.
-- DEMO STAND-IN: reads the borrowers seed (B-1001..B-1004 = valid borrowers).
-- Production: swap the `from` to {{ source('bronze', 'borrower') }} once the
-- Debezium -> Iceberg sink is live (see sources.yml).
select
    id,
    full_name
from {{ ref('borrowers') }}
