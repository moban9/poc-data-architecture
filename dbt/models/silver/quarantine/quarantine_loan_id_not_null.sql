{{ config(
    materialized='table',
    schema='silver',
    post_hook="{{ quarantine_insert('silver','loan','not_null__id','not_null','loan.id is null or empty string','batch', loan_offending_row(), this, ref('quarantine')) }}"
) }}

-- Per-rule quarantine: isolate rows that violate not_null(id).
-- Runs BEFORE the clean loan model (loan.sql refs this model for ordering).
-- The post_hook appends the violating rows to lakehouse.quarantine_lms.
select
    id,
    amount,
    currency,
    origination_date,
    borrower_id
from {{ ref('stg_loan') }}
where id is null or id = ''
