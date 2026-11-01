-- Silver model: dim_borrower
-- Borrower dimension. One row per borrower id.
-- TODO(Meridian): add attribute columns (name, email, ...) as the bronze
-- borrower source is confirmed.
select
    id,
    full_name
from {{ source('bronze', 'borrower') }}
