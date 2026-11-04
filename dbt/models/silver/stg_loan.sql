{{ config(materialized='table', schema='silver') }}

-- Raw loan staging — the Silver boundary's upstream input (ALL rows, bad included).
--
-- PRODUCTION WIRING: reads the live Bronze CDC stream
-- (source('bronze','loan')) instead of the demo dirty_data seed.
-- `amount` is staged as a plain numeric (the LMS source is NUMERIC(18,2)).
-- The previous base64 decode (macros/decode_amount.sql) was a workaround for a
-- sink that never emitted data; it is no longer applied.
select
    id,
    cast(amount as double) as amount,
    currency,
    origination_date,
    borrower_id
from {{ source('bronze', 'loan') }}
