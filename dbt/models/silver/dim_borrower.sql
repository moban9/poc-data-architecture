{{ config(materialized='table', schema='silver') }}

-- Borrower dimension. One row per borrower id.
-- PRODUCTION WIRING: reads the live Bronze CDC `borrower` table
-- (source('bronze','borrower')) instead of the demo borrowers seed.
-- Collapsed to the newest record per id: Bronze is an append-only changelog
-- (latest_cdc_row, see docs/09), so a re-snapshot or a sink replay would
-- otherwise produce duplicate borrowers and break the unique(id) test.
select
    id,
    full_name
from (
    {{ latest_cdc_row(source('bronze', 'borrower'), 'id, full_name') }}
)
