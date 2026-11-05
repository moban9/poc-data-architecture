{{ config(materialized='table', schema='gold') }}

-- Gold: daily event rollup — loan event activity per calendar day, per currency.
-- Grain: (event_date, currency). Aggregates the Silver `loan_event` stream (joined
-- to Silver `loan` on loan_id) into per-day, per-currency counts and amounts.
--
-- ── CURRENCY DECISION (Keystone, t_8cbf9a27) ─────────────────────────────────
-- The grain now carries `currency` so every payments money KPI is sliceable by
-- ISO-4217 code (same option (a) as loan_portfolio_summary.sql). `disbursement_amount`
-- / `payment_amount` are NOMINAL per currency; SUM-ing them across currencies is a
-- mixed-currency nominal figure, NOT a real total — there is no FX conversion. BI
-- must slice money KPIs by currency. The inner join to `loan` also drops any event
-- whose loan failed Silver DQ (an orphaned event belongs to no valid loan and must
-- not enter the money KPI).

select
    cast(e.occurred_at as date) as event_date,
    l.currency as currency,
    count(*) as total_events,
    count(*) filter (where e.event_type = 'origination') as origination_count,
    count(*) filter (where e.event_type = 'disbursement') as disbursement_count,
    count(*) filter (where e.event_type = 'payment') as payment_count,
    round(coalesce(sum(e.amount) filter (where e.event_type = 'disbursement'), 0.0), 2) as disbursement_amount,
    round(coalesce(sum(e.amount) filter (where e.event_type = 'payment'), 0.0), 2) as payment_amount
from {{ ref('loan_event') }} e
join {{ ref('loan') }} l on l.id = e.loan_id
group by cast(e.occurred_at as date), l.currency
order by event_date, currency
