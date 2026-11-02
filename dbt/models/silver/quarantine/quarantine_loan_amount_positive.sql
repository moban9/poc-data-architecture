{{ config(
    materialized='table',
    schema='silver',
    post_hook="{{ quarantine_insert('silver','loan','positive_value__amount','positive_value','loan.amount must be > 0 (non-positive value)','batch', loan_offending_row(), this, ref('quarantine')) }}"
) }}

-- Per-rule quarantine: isolate rows that violate positive_value(amount).
-- Runs BEFORE the clean loan model. Post_hook appends to lakehouse.quarantine_lms.
select
    id,
    amount,
    currency,
    origination_date,
    borrower_id
from {{ ref('stg_loan') }}
where amount <= 0
