-- Silver model: loan
-- Minimal staging passthrough from the Bronze CDC append-only stream.
-- TODO(Meridian): add CDC dedup / SCD2 (latest-row-per-id) once the Debezium
-- sink's metadata columns (op, ts_ms) are finalized.
select
    id,
    amount,
    currency,
    origination_date,
    borrower_id
from {{ source('bronze', 'loan') }}
