-- Silver model: loan_event
-- Staging passthrough from the Bronze CDC append-only stream.
-- `amount` is carried through (disbursement/payment amounts; NULL for
-- origination) so Gold can derive outstanding balance and delinquency.
--
-- `occurred_at` arrives as an ISO-8601 string (Debezium's default encoding for
-- `timestamp with time zone` through the JsonConverter). Parse it to a proper
-- `timestamp with time zone` here so the Gold rollups can cast/date_diff it.
select
    id,
    loan_id,
    event_type,
    amount,
    from_iso8601_timestamp(occurred_at) as occurred_at
from {{ source('bronze', 'loan_event') }}
