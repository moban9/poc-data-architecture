{{ config(
    materialized='table',
    schema='silver',
    post_hook="{{ quarantine_insert('silver','loan','accepted_values__currency','accepted_values','loan.currency not in accepted ISO 4217 set','batch', loan_offending_row(), this, ref('quarantine')) }}"
) }}

-- Per-rule quarantine: isolate rows that violate not_null(currency) + accepted_values(currency).
-- Runs BEFORE the clean loan model. Post_hook appends to lakehouse.quarantine_lms.
select
    id,
    amount,
    currency,
    origination_date,
    borrower_id
from {{ ref('stg_loan') }}
where currency is null
   or currency not in ('USD', 'EUR', 'GBP', 'JPY', 'CAD', 'AUD')
