"""Shared constants for the LMS source service.

The dirty modes and seed borrowers are coupled to the Silver dbt DQ rules in
`dbt/models/schema.yml` (and the `borrowers` seed that backs `dim_borrower` in
the current demo wiring). Keep them in sync with that project.
"""

# ISO-4217 currencies accepted by the Silver `accepted_values` rule on loan.currency.
VALID_CURRENCIES = ["USD", "EUR", "GBP", "JPY", "CAD", "AUD"]

# Borrowers that MUST exist so the Silver relationships rule
# (loan.borrower_id -> dim_borrower.id) passes for clean rows. These mirror
# dbt/seeds/borrowers.csv (B-1001..B-1004), which currently backs dim_borrower.
SEED_BORROWERS = [
    ("B-1001", "Alice Example"),
    ("B-1002", "Bob Example"),
    ("B-1003", "Carol Example"),
    ("B-1004", "Dave Example"),
]

# A borrower id deliberately absent from both the source borrower table and
# dim_borrower: referencing it trips the relationships test (orphan borrower).
ORPHAN_BORROWER_ID = "B-9999"

# The five dirty modes, one per Silver DQ rule they trip.
DIRTY_MODES = [
    "null_loan_id",          # loan_event.loan_id is NULL        -> not_null + relationships
    "negative_amount",       # loan.amount <= 0                  -> positive_value
    "invalid_date",          # loan.origination_date != YYYY-MM-DD -> valid_date
    "unsupported_currency",  # loan.currency not in VALID_CURRENCIES -> accepted_values
    "orphan_borrower_id",    # loan.borrower_id not in borrower  -> relationships
]

# Allowed values for POST /generate?mode=...
VALID_GENERATE_MODES = ["clean", "dirty", "mixed"]

# Fraction of dirty rows produced by mode="mixed" (~10%).
MIXED_DIRTY_RATE = 0.10
