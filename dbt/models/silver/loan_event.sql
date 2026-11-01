-- Silver model: loan_event
-- Minimal staging passthrough from the Bronze CDC append-only stream.
select
    id,
    loan_id,
    event_type,
    occurred_at
from {{ source('bronze', 'loan_event') }}
