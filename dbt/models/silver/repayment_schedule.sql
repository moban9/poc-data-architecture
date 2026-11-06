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
--
-- CURRENCY RULE (Keystone, t_8cbf9a27): `currency` is denormalized from the parent
-- loan via the join on loan_id -> loan.currency. principal_due / interest_due are
-- NOMINAL per that currency — never SUM them across currencies (no FX conversion;
-- see gold/loan_portfolio_summary.sql, option (a)).

select
    s.id,
    s.loan_id,
    l.currency as currency,
    s.installment_no,
    s.due_date,
    s.principal_due,
    s.interest_due,
    s.status
from {{ ref('stg_repayment_schedule') }} s
join {{ ref('loan') }} l on l.id = s.loan_id
where
    -- not_null(id) (also excludes empty string)
    s.id is not null and s.id <> ''
    -- not_null(loan_id) + relationships(loan_id -> loan.id): enforced by the inner
    -- join on l.id = s.loan_id (null/empty/unknown loan_id yields no match -> dropped)
    -- not_null(installment_no) + positive instalment number
    and s.installment_no is not null and s.installment_no > 0
    -- not_null(due_date) + valid_date(due_date)
    and s.due_date is not null
    and regexp_like(cast(s.due_date as varchar), '^\d{4}-\d{2}-\d{2}$')
    -- not_null(principal_due / interest_due) + non-negative
    and s.principal_due is not null and s.principal_due >= 0
    and s.interest_due is not null and s.interest_due >= 0
    -- accepted_values(status)
    and s.status in ('scheduled', 'paid', 'overdue')
