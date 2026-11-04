-- Silver model: loan_event
-- Staging passthrough from the Bronze CDC append-only stream.
-- `amount` is carried through (disbursement/payment amounts; NULL for
-- origination) so Gold can derive outstanding balance and delinquency.
select
    id,
    loan_id,
    event_type,
    amount,
    occurred_at
from {{ source('bronze', 'loan_event') }}
