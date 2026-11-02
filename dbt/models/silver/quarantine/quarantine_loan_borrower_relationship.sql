{{ config(
    materialized='table',
    schema='silver',
    post_hook="{{ quarantine_insert('silver','loan','relationships__borrower_id__dim_borrower','relationships','loan.borrower_id has no matching dim_borrower.id','batch', loan_offending_row(), this, ref('quarantine')) }}"
) }}

-- Per-rule quarantine: isolate rows that violate not_null(borrower_id) +
-- relationships(borrower_id -> dim_borrower.id).
-- Runs BEFORE the clean loan model. Post_hook appends to lakehouse.quarantine_lms.
select
    s.id,
    s.amount,
    s.currency,
    s.origination_date,
    s.borrower_id
from {{ ref('stg_loan') }} as s
where s.borrower_id is null
   or not exists (
        select 1
        from {{ ref('dim_borrower') }} as b
        where b.id = s.borrower_id
   )
