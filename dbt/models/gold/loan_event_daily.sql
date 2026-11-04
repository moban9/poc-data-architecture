{{ config(materialized='table', schema='gold') }}

-- Gold: daily event rollup — loan event activity per calendar day.
-- Aggregates the Silver `loan_event` stream into per-day counts and amounts.

select
    cast(occurred_at as date) as event_date,
    count(*) as total_events,
    count(*) filter (where event_type = 'origination') as origination_count,
    count(*) filter (where event_type = 'disbursement') as disbursement_count,
    count(*) filter (where event_type = 'payment') as payment_count,
    round(coalesce(sum(amount) filter (where event_type = 'disbursement'), 0.0), 2) as disbursement_amount,
    round(coalesce(sum(amount) filter (where event_type = 'payment'), 0.0), 2) as payment_amount
from {{ ref('loan_event') }}
group by cast(occurred_at as date)
order by event_date
