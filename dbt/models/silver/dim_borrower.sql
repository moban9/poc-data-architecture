{{ config(materialized='table', schema='silver') }}

-- Borrower dimension. One row per borrower id.
-- PRODUCTION WIRING: reads the live Bronze CDC `borrower` table
-- (source('bronze','borrower')) instead of the demo borrowers seed.
select
    id,
    full_name
from {{ source('bronze', 'borrower') }}
