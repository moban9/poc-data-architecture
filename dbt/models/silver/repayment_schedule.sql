{{ config(materialized='table', schema='silver') }}

-- Silver model: repayment_schedule (CLEAN) — the passing-only complement of the
-- Bronze repayment_schedule stream.
--
-- The source guarantees a well-formed repayment contract (see src/lms/models.py):
-- loan_id / installment_no / due_date / principal_due / interest_due / status are
-- never null or malformed, and the schedule is never part of an engineered dirty
-- mode. This model enforces those invariants and, for referential integrity, keeps
-- only instalments whose loan survived Silver DQ (loan_id -> silver.loan.id).
-- The business key is (loan_id, installment_no), enforced in the source.

select
    id,
    loan_id,
    installment_no,
    due_date,
    principal_due,
    interest_due,
    status
from {{ ref('stg_repayment_schedule') }}
where
    -- not_null(id) (also excludes empty string)
    id is not null and id <> ''
    -- not_null(loan_id) + relationships(loan_id -> loan.id)
    and loan_id is not null and loan_id <> ''
    and loan_id in (select id from {{ ref('loan') }})
    -- not_null(installment_no) + positive instalment number
    and installment_no is not null and installment_no > 0
    -- not_null(due_date) + valid_date(due_date)
    and due_date is not null
    and regexp_like(cast(due_date as varchar), '^\d{4}-\d{2}-\d{2}$')
    -- not_null(principal_due / interest_due) + non-negative
    and principal_due is not null and principal_due >= 0
    and interest_due is not null and interest_due >= 0
    -- accepted_values(status)
    and status in ('scheduled', 'paid', 'overdue')
