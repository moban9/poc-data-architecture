{{ config(
    materialized='table',
    schema='silver',
    post_hook="{{ quarantine_insert('silver','loan','valid_date__origination_date','valid_date','loan.origination_date is not a valid ISO date (YYYY-MM-DD)','batch', loan_offending_row(), this, ref('quarantine')) }}"
) }}

-- Per-rule quarantine: isolate rows that violate not_null(origination_date) + valid_date(origination_date).
-- Runs BEFORE the clean loan model. Post_hook appends to lakehouse.quarantine_lms.
select
    id,
    amount,
    currency,
    origination_date,
    borrower_id
from {{ ref('stg_loan') }}
where origination_date is null
   or not regexp_like(cast(origination_date as varchar), '^\d{4}-\d{2}-\d{2}$')
