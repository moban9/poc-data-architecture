{{ config(materialized='table', schema='silver') }}

-- Silver model: loan (CLEAN) — the passing-only complement.
--
-- Reads the rows from stg_loan that satisfy EVERY loan DQ rule. The violating
-- rows were isolated FIRST by the per-rule quarantine models (which append them
-- to lakehouse.quarantine_lms via post_hooks). The ref() calls in the comments
-- below register those models as upstream deps so quarantine runs BEFORE this
-- model; the WHERE clause is the logical complement (anti-join) of the per-rule
-- violation predicates.

-- Dependency ordering (per-rule quarantine runs first):
--   {{ ref('quarantine_loan_id_not_null') }}
--   {{ ref('quarantine_loan_amount_positive') }}
--   {{ ref('quarantine_loan_currency_accepted') }}
--   {{ ref('quarantine_loan_origination_date_valid') }}
--   {{ ref('quarantine_loan_borrower_relationship') }}

select
    id,
    amount,
    currency,
    origination_date,
    borrower_id,
    term_months,
    disbursement_date,
    interest_rate,
    monthly_installment,
    maturity_date
from {{ ref('stg_loan') }}
where
    -- not_null(id) (also excludes empty string for robustness)
    id is not null and id <> ''
    -- positive_value(amount)
    and amount > 0
    -- not_null(currency) + accepted_values(currency)
    and currency is not null
    and currency in ('IDR')
    -- not_null(origination_date) + valid_date(origination_date)
    and origination_date is not null
    and regexp_like(cast(origination_date as varchar), '^\d{4}-\d{2}-\d{2}$')
    -- not_null(borrower_id) + relationships(borrower_id -> dim_borrower.id)
    and borrower_id is not null
    and borrower_id in (select id from {{ ref('dim_borrower') }})
