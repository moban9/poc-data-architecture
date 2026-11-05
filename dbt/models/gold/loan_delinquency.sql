{{ config(materialized='table', schema='gold') }}

{%- set term_days = 365 %}  {# ASSUMPTION: standard 12-month loan term (the source has no term/maturity column) #}

-- Gold: NPL / delinquency — disbursed loans bucketed by days past due, with a
-- REAL portfolio-level NPL rate = (90+ outstanding) / (total outstanding).
--
-- DAYS-PAST-DUE DERIVATION (the source has NO due_date, payment schedule, or
-- maturity column — see schema.yml):
--
--   The `loan_event.occurred_at` timestamps are CDC/demo *ingestion* times: every
--   disbursement/payment event is clustered inside a ~60-day snapshot window and
--   therefore carries no business delinquency signal. The only business-time
--   column in the schema is `loan.origination_date` (when the loan was actually
--   funded). Days-past-due is anchored to that column, plus a term assumption:
--
--       dpd = as_of_date - origination_date - term_days      (floored at 0)
--
--   * as_of_date = max(loan_event.occurred_at)  — the dataset's latest event
--     (the deterministic pipeline "as of" timestamp).
--   * term_days  = 365  — ASSUMPTION: a standard 12-month loan term. A loan is
--     "current" until it matures (origination_date + 12 months); each day past
--     term counts as one day past due.
--
--   Buckets (days past due): current (0-29), 30-59, 60-89, 90+ (>=90, NPL).
--   outstanding = principal - total payments received (floored at 0).
--   npl_rate    = sum(outstanding for 90+) / sum(outstanding for all buckets),
--                 carried on every row (portfolio-level KPI).

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

delinquent as (
    select
        greatest(l.amount - coalesce(p.total_paid, 0.0), 0.0) as outstanding,
        greatest(
            date_diff('day', cast(l.origination_date as date), a.ref_dt) - {{ term_days }},
            0
        ) as dpd
    from {{ ref('loan') }} l
    join disbursed d on d.loan_id = l.id
    left join payments p on p.loan_id = l.id
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
    round(t.npl_outstanding / t.total_outstanding, 4) as npl_rate
from grouped g
cross join totals t
order by
    case g.delinquency_bucket
        when 'current' then 1
        when '30-59' then 2
        when '60-89' then 3
        else 4
    end
