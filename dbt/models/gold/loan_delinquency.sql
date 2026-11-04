{{ config(materialized='table', schema='gold') }}

-- Gold: NPL / delinquency — disbursed loans bucketed by days past due, with
-- charge-off as a first-class state (no longer lumped into 90+).
--
-- DERIVATION NOTE: the source has no payment schedule or due date, so "days
-- past due" is derived from payment events: for each disbursed loan, the days
-- elapsed since its most recent payment (or since disbursement if it has never
-- paid), measured against the dataset's latest event timestamp (the as-of date).
--
--   current     (0-29 days past due)
--   30-59       (30-59 days past due)
--   60-89       (60-89 days past due)
--   90-179      (90-179 days past due — non-performing, not yet charged off)
--   charge-off  (>=180 days past due — first-class state)
--
-- npl_rate = (90-179 + charge-off) / total disbursed loans (portfolio-level
-- KPI). Computed once at portfolio level and carried on every row.

with payments as (
    select
        loan_id,
        sum(amount) as total_paid
    from {{ ref('loan_event') }}
    where event_type = 'payment'
    group by loan_id
),

disbursed as (
    select
        l.id,
        l.amount as principal,
        max(e.occurred_at) filter (where e.event_type = 'disbursement') as disbursed_at,
        max(e.occurred_at) filter (where e.event_type = 'payment') as last_paid_at
    from {{ ref('loan') }} l
    join {{ ref('loan_event') }} e on e.loan_id = l.id
    where e.event_type in ('disbursement', 'payment')
    group by l.id, l.amount
),

delinquent as (
    select
        greatest(d.principal - coalesce(p.total_paid, 0.0), 0.0) as outstanding,
        case
            when date_diff('day', coalesce(d.last_paid_at, d.disbursed_at), a.ref_dt) < 30 then 'current'
            when date_diff('day', coalesce(d.last_paid_at, d.disbursed_at), a.ref_dt) < 60 then '30-59'
            when date_diff('day', coalesce(d.last_paid_at, d.disbursed_at), a.ref_dt) < 90 then '60-89'
            when date_diff('day', coalesce(d.last_paid_at, d.disbursed_at), a.ref_dt) < 180 then '90-179'
            else 'charge-off'
        end as delinquency_bucket
    from disbursed d
    left join payments p on p.loan_id = d.id
    cross join (select max(occurred_at) as ref_dt from {{ ref('loan_event') }}) a
    where d.disbursed_at is not null
),

grouped as (
    select
        delinquency_bucket,
        count(*) as loan_count,
        round(sum(outstanding), 2) as outstanding_balance
    from delinquent
    group by delinquency_bucket
)

select
    g.delinquency_bucket,
    g.loan_count,
    g.outstanding_balance,
    round(cast(t.npl_loans as double) / t.total_loans, 4) as npl_rate
from grouped g
cross join (
    select
        sum(case when delinquency_bucket in ('90-179', 'charge-off') then loan_count else 0 end) as npl_loans,
        sum(loan_count) as total_loans
    from grouped
) t
