{{ config(materialized='table', schema='gold') }}

-- Gold: NPL / delinquency — disbursed loans bucketed by days past due (DPD),
-- with a REAL portfolio-level NPL rate = (90+ outstanding) / (total outstanding).
--
-- DAYS-PAST-DUE DERIVATION (from the REAL repayment_schedule.due_date — no
-- 365-day term assumption):
--
--   as_of = max(loan_event.occurred_at)  — the dataset's latest event ("now").
--     POST /scenarios/loan-book anchors the current loan's latest payment at
--     generation time, so as_of lands at "now".
--   dpd   = as_of - min(due_date over 'overdue' instalments), floored at 0.
--     A loan with no overdue instalment has dpd = 0 (current).
--
--   outstanding = principal (loan.amount) - total payments received (floored at 0).
--   Buckets: current (<30) / 30-59 / 60-89 / 90+ (>=90 = NPL).
--   npl_rate = 90+ outstanding / total outstanding (portfolio-level KPI, carried
--              on every row).

with payments as (
    select
        loan_id,
        sum(amount) as total_paid
    from {{ ref('loan_event') }}
    where event_type = 'payment'
    group by loan_id
),

disbursed as (
    select distinct loan_id
    from {{ ref('loan_event') }}
    where event_type = 'disbursement'
),

asof as (
    select cast(max(occurred_at) as date) as ref_dt
    from {{ ref('loan_event') }}
),

oldest_overdue as (
    select
        loan_id,
        min(cast(due_date as date)) as first_overdue_due
    from {{ ref('repayment_schedule') }}
    where status = 'overdue'
    group by loan_id
),

delinquent as (
    select
        greatest(l.amount - coalesce(p.total_paid, 0.0), 0.0) as outstanding,
        coalesce(
            date_diff('day', o.first_overdue_due, a.ref_dt),
            0
        ) as dpd
    from {{ ref('loan') }} l
    join disbursed d on d.loan_id = l.id
    left join payments p on p.loan_id = l.id
    left join oldest_overdue o on o.loan_id = l.id
    cross join asof a
),

grouped as (
    select
        case
            when dpd < 30 then 'current'
            when dpd < 60 then '30-59'
            when dpd < 90 then '60-89'
            else '90+'
        end as delinquency_bucket,
        count(*) as loan_count,
        sum(outstanding) as outstanding_balance
    from delinquent
    group by 1
),

totals as (
    select
        sum(outstanding_balance) as total_outstanding,
        sum(case when delinquency_bucket = '90+' then outstanding_balance else 0 end) as npl_outstanding
    from grouped
)

select
    g.delinquency_bucket,
    g.loan_count,
    round(g.outstanding_balance, 2) as outstanding_balance,
    round(t.npl_outstanding / nullif(t.total_outstanding, 0), 4) as npl_rate
from grouped g
cross join totals t
order by
    case g.delinquency_bucket
        when 'current' then 1
        when '30-59' then 2
        when '60-89' then 3
        else 4
    end
