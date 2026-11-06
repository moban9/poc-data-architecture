"""Shared constants for the LMS source service.

The dirty modes and seed borrowers are coupled to the Silver dbt DQ rules in
`dbt/models/schema.yml` (and the `borrowers` seed that backs `dim_borrower` in
the current demo wiring). Keep them in sync with that project.
"""

# Single-currency POC: IDR only. The Silver `accepted_values` rule on
# loan.currency must accept exactly this set (one value).
VALID_CURRENCIES = ["IDR"]

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

# The four dirty modes, one per Silver DQ rule they trip. There is no currency
# dirty mode: the source only ever emits IDR (single-currency POC), so a
# "bad currency" defect would be a foreign/non-IDR value and is deliberately
# dropped rather than reintroducing a foreign currency.
DIRTY_MODES = [
    "null_loan_id",          # loan_event.loan_id is NULL        -> not_null + relationships
    "negative_amount",       # loan.amount <= 0                  -> positive_value
    "invalid_date",          # loan.origination_date != YYYY-MM-DD -> valid_date
    "orphan_borrower_id",    # loan.borrower_id not in borrower  -> relationships
]

# Allowed values for POST /generate?mode=...
VALID_GENERATE_MODES = ["clean", "dirty", "mixed"]

# Fraction of dirty rows produced by mode="mixed" (~10%).
MIXED_DIRTY_RATE = 0.10

# ── Repayment contract (NPL) ─────────────────────────────────────────────────
# Variable loan term, default 12 months (per the confirmed design).
LOAN_TERM_DEFAULT = 12
LOAN_TERMS = [6, 12, 24, 36]

# Annual interest-rate range (percent) sampled for /generate.
INTEREST_RATE_MIN = 6.0
INTEREST_RATE_MAX = 24.0

# Deterministic loan-book parameters (POST /scenarios/loan-book): a fixed term,
# a fixed rate, and a fixed number of on-time instalments before the loan stops
# paying. The (paid+1)-th instalment's due_date is the delinquency anchor.
LOAN_BOOK_TERM = 12
LOAN_BOOK_RATE = 12.0
LOAN_BOOK_PAID_INSTALLMENTS = 3

# repayment_schedule.status values (consumed by the Gold NPL model).
REPAYMENT_STATUS_SCHEDULED = "scheduled"
REPAYMENT_STATUS_PAID = "paid"
REPAYMENT_STATUS_OVERDUE = "overdue"
