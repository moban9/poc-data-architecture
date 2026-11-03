{{ config(materialized='table', schema='gold') }}

-- Gold: loan portfolio by currency.
-- Aggregates the CLEAN Silver `loan` model (bad rows already isolated to
-- quarantine) into a per-currency portfolio roll-up.
select
    currency,
    count(*) as loan_count,
    round(sum(amount), 2) as total_amount,
    round(avg(amount), 2) as avg_amount
from {{ ref('loan') }}
group by currency
