{{ config(materialized='table', schema='silver') }}

-- Raw loan staging — the Silver boundary's upstream input (ALL rows, bad included).
--
-- PRODUCTION WIRING: reads the live Bronze CDC stream
-- (source('bronze','loan')) instead of the demo dirty_data seed.
--
-- Money columns (amount, interest_rate, monthly_installment) arrive as JSON
-- doubles (Debezium decimal.handling.mode=double), so they are cast to double.
-- term_months (INTEGER) is cast to integer. The ISO date columns
-- (origination_date, disbursement_date, maturity_date) are VARCHAR passthrough.

select
    id,
    cast(amount as double) as amount,
    currency,
    origination_date,
    borrower_id,
    cast(term_months as integer) as term_months,
    disbursement_date,
    cast(interest_rate as double) as interest_rate,
    cast(monthly_installment as double) as monthly_installment,
    maturity_date
from {{ source('bronze', 'loan') }}
