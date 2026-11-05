{{ config(materialized='table', schema='gold') }}

-- Gold: loan portfolio summary — one row per (loan_status, loan_type, currency).
--
-- DIMENSION DERIVATION NOTE: the source schema carries no explicit
-- `loan_status` or `loan_type` column (loan = id, amount, currency,
-- origination_date, borrower_id; loan_event = id, loan_id, event_type, amount,
-- occurred_at). Both dimensions are therefore DERIVED from real data:
--
--   loan_status — event lifecycle:
--       'originated'  -> has an origination event but no disbursement yet
--       'disbursed'   -> funded, but no payment received yet
--       'repaying'    -> funded and at least one payment received
--   loan_type — principal-size tier (no product type exists in source):
--       'micro'  <  25,000
--       'small'   25,000 – 50,000
--       'medium'  50,000 – 75,000
--       'large'   >= 75,000
--
-- outstanding_balance = principal - total payments received (floored at 0).
--
-- ── CURRENCY DECISION (Keystone, t_51346c5a) ────────────────────────────────
-- The gold grain now carries `currency` so every money KPI is sliceable by
-- ISO-4217 code. This is option (a) of the BI ask, chosen deliberately over the
-- alternatives:
--   (a) CHOSEN — currency in the grain (loan_status × loan_type × currency).
--   (b) DEFERRED — a `usd_equivalent` column requires a documented FX source.
--       None exists in the POC, and Keystone will not fabricate rates. When
--       Meridian/Cask supply a `dim_currency_rate` (currency, rate, rate_date,
--       source) — a fixed POC table is fine IF the source + as-of date are
--       stated in the model — `usd_equivalent = amount * rate` is a drop-in
--       addition to this model's final select.
--   (c) REJECTED — the source is NOT single-currency-in-practice: src/lms
--       `_random_currency()` draws from six codes (USD/EUR/GBP/JPY/CAD/AUD). A
--       `count(distinct currency) = 1` test would fail by construction. The
--       currency dimension is instead enforced by the `accepted_values` test on
--       this column in models/schema.yml.
--
-- CONSEQUENCE FOR BI: `total_principal` / `outstanding_balance` / `avg_amount`
--   are NOMINAL per currency. SUM-ing them across currencies yields a mixed-
--   currency nominal figure, NOT a real total — there is no FX conversion. Any
--   headline money KPI must slice by currency (or filter to one currency). The
--   "Book by currency" card moves from silver.loan to this mart. Existing
--   status/tier cards (GROUP BY loan_status / loan_type) remain correct: they
--   aggregate over the finer grain.

with events as (
    select
        loan_id,
        count(*) filter (where event_type = 'disbursement') as disbursement_count,
        count(*) filter (where event_type = 'payment') as payment_count,
        coalesce(sum(amount) filter (where event_type = 'payment'), 0.0) as total_paid
    from {{ ref('loan_event') }}
    where loan_id is not null
    group by loan_id
),

enriched as (
    select
        l.id,
        l.amount as principal,
        l.currency as currency,
        coalesce(e.total_paid, 0.0) as total_paid,
        case
            when coalesce(e.disbursement_count, 0) = 0 then 'originated'
            when coalesce(e.payment_count, 0) = 0 then 'disbursed'
            else 'repaying'
        end as loan_status,
        case
            when l.amount < 25000 then 'micro'
            when l.amount < 50000 then 'small'
            when l.amount < 75000 then 'medium'
            else 'large'
        end as loan_type
    from {{ ref('loan') }} l
    left join events e on e.loan_id = l.id
)

select
    loan_status,
    loan_type,
    currency,
    count(*) as loan_count,
    round(sum(principal), 2) as total_principal,
    round(avg(principal), 2) as avg_amount,
    round(sum(greatest(principal - total_paid, 0.0)), 2) as outstanding_balance
from enriched
group by loan_status, loan_type, currency
