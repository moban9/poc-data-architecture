{{ config(materialized='table', schema='gold') }}

-- Gold: daily loan origination volume.
-- Loans originated per calendar day (from the clean Silver `loan` model).
select
    origination_date,
    count(*) as loan_count,
    round(sum(amount), 2) as total_amount
from {{ ref('loan') }}
group by origination_date
