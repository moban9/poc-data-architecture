-- Silver model: loan_event (CLEAN)
-- Reads the Bronze CDC append-only stream, collapsed to one row per id
-- (latest_cdc_row — Bronze is a changelog, see docs/09), then enforces the
-- model's own data-quality rules:
--   * not_null(id)                      — so the unique test holds by construction;
--   * not_null(loan_id)                 — 4,197 source rows carry a NULL loan_id;
--   * relationships(loan_id -> loan.id) — 35,073 events belong to loans that the
--     loan DQ rules removed from silver.loan (bad amount / currency / dates /
--     borrower). Keeping them makes the referential test fail forever and counts
--     payments against loans that do not exist in the clean layer.
-- Same pattern as silver/repayment_schedule.sql (inner join to silver.loan).
-- excluded rows are captured by the on-run-end quarantine hook, which appends
-- every failing test's offending rows to lakehouse.quarantine_lms.
--
-- `amount` is carried through (disbursement/payment amounts; NULL for
-- origination) so Gold can derive outstanding balance and delinquency.
--
-- `occurred_at` arrives as an ISO-8601 string (Debezium's default encoding for
-- `timestamp with time zone` through the JsonConverter). Parse it to a proper
-- `timestamp with time zone` here so the Gold rollups can cast/date_diff it.
select
    e.id,
    e.loan_id,
    e.event_type,
    e.amount,
    from_iso8601_timestamp(e.occurred_at) as occurred_at
from (
    {{ latest_cdc_row(source('bronze', 'loan_event'),
         'id, loan_id, event_type, amount, occurred_at') }}
) e
join {{ ref('loan') }} l on l.id = e.loan_id
where
    e.id is not null and e.id <> ''
    -- not_null(loan_id) + relationships(loan_id -> loan.id): the inner join
    -- enforces the relationship; this drops empty-string keys.
    and e.loan_id is not null and e.loan_id <> ''
