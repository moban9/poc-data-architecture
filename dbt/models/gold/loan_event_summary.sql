{{ config(materialized='table', schema='gold') }}

-- Gold: loan event activity by event type.
-- Aggregates the Silver `loan_event` stream into per-event-type activity.
select
    event_type,
    count(*) as event_count,
    count(distinct loan_id) as distinct_loans
from {{ ref('loan_event') }}
group by event_type
