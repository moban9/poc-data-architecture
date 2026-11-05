{{ config(
    materialized='incremental',
    incremental_strategy='append',
    schema='gold'
) }}

-- Gold: NPL / delinquency SNAPSHOT HISTORY — the time series that the
-- point-in-time `gold.loan_delinquency` mart cannot provide.
--
-- Grain: (as_of_date, delinquency_bucket) — the existing delinquency columns
-- plus an `as_of_date` partition key. One row per bucket per snapshot date.
--
-- MATERIALIZATION CONTRACT (append-only, no unique_key — same pattern as the
-- quarantine table):
--   * materialized='incremental' + incremental_strategy='append': the FIRST
--     `dbt run` creates the table with the current snapshot; every later run
--     INSERTs only rows whose `as_of_date` is not already present. The table is
--     NEVER dropped, so prior snapshots survive (the append-only history log).
--   * `as_of_date = cast(max(loan_event.occurred_at) as date)` — the dataset's
--     "now", the SAME value `loan_delinquency` already computes. Re-running dbt
--     on the same day inserts ZERO rows (the `is_incremental()` guard filters
--     the already-present date), so snapshots never duplicate within a day.
--   * No synthesized history: a backfill is only meaningful once the pipeline
--     has run on multiple distinct `as_of_date` values. An empty-then-growing
--     table is correct; the BI panel renders whatever is real.
--
-- DERIVATION: identical to `loan_delinquency` (days-past-due from the REAL
-- repayment_schedule.due_date, not a 365-day term assumption):
--   dpd = as_of_date - min(due_date over 'overdue' instalments), floored at 0.
--   outstanding = principal (loan.amount) - total payments received, floored at 0.
--   buckets = current (<30) / 30-59 / 60-89 / 90+ (>=90 = NPL).
--   npl_rate = 90+ outstanding / total outstanding, carried on every bucket row.
--
-- CURRENCY CAVEAT: `outstanding_balance` is a NOMINAL multi-currency sum (the
-- source writes USD/EUR/GBP/JPY/CAD/AUD with no FX conversion). The NPL *rate*
-- is a ratio of two mixed-currency totals (dimensionless and meaningful); the
-- *balance* is not. Do not treat a cross-currency outstanding total as a real
-- figure. (A currency dimension in this snapshot is a possible follow-up; it is
-- deliberately out of scope for t_51346c5a, whose grain is fixed by the BI ask.)

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
        a.ref_dt as as_of_date,
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
        as_of_date,
        case
            when dpd < 30 then 'current'
            when dpd < 60 then '30-59'
            when dpd < 90 then '60-89'
            else '90+'
        end as delinquency_bucket,
        count(*) as loan_count,
        sum(outstanding) as outstanding_balance
    from delinquent
    group by 1, 2
),

totals as (
    select
        as_of_date,
        sum(outstanding_balance) as total_outstanding,
        sum(case when delinquency_bucket = '90+' then outstanding_balance else 0 end) as npl_outstanding
    from grouped
    group by as_of_date
),

final as (
    select
        g.as_of_date,
        g.delinquency_bucket,
        g.loan_count,
        round(g.outstanding_balance, 2) as outstanding_balance,
        round(t.npl_outstanding / nullif(t.total_outstanding, 0), 4) as npl_rate
    from grouped g
    join totals t on t.as_of_date = g.as_of_date
)

select *
from final
{% if is_incremental() %}
where as_of_date not in (select distinct as_of_date from {{ this }})
{% endif %}
order by
    as_of_date,
    case delinquency_bucket
        when 'current' then 1
        when '30-59' then 2
        when '60-89' then 3
        else 4
    end
