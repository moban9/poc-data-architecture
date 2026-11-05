{{ config(materialized='table', schema='silver') }}

-- Raw repayment_schedule staging — the Silver boundary's upstream input (ALL
-- DQ-bad rows included, but ONE ROW PER id: latest_cdc_row() collapses the
-- Bronze CDC changelog to its newest version per id, see docs/09).
-- Reads the live Bronze CDC stream (source('bronze','repayment_schedule')).
--
-- principal_due / interest_due arrive as JSON doubles (Debezium
-- decimal.handling.mode=double), so they are cast to double; installment_no is
-- cast to integer; due_date / status are VARCHAR passthrough.

select
    id,
    loan_id,
    cast(installment_no as integer) as installment_no,
    due_date,
    cast(principal_due as double) as principal_due,
    cast(interest_due as double) as interest_due,
    status
from (
    {{ latest_cdc_row(source('bronze', 'repayment_schedule'),
         'id, loan_id, installment_no, due_date, principal_due, interest_due, status') }}
)
