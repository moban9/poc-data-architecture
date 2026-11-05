"""Verification for the LMS repayment-contract (NPL) changes.

Run standalone (no DB needed — imports the SQLAlchemy models + pure generation
functions and asserts on their output):

    python tests/test_repayment_schedule.py

Also pytest-compatible (test_* functions). Checks:

  * loan + repayment_schedule DDL carry the real due_date / term columns;
  * _amortize returns a correct monthly-annuity schedule;
  * _make_loan_unit emits a fully-populated loan + schedule;
  * _loan_book_unit encodes each bucket's days-past-due in the oldest overdue
    repayment_schedule.due_date (and maps to the right Gold bucket);
  * NPL_BUCKETS gold_bucket values are exactly the Gold model's accepted set.
"""
from __future__ import annotations

import os
import sys
from datetime import date, datetime, timezone

# Make `src/lms` importable when run from anywhere.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sqlalchemy.dialects import postgresql  # noqa: E402
from sqlalchemy.schema import CreateTable  # noqa: E402

import app  # noqa: E402
import constants  # noqa: E402
import models  # noqa: E402

GOLD_BUCKETS = {"current", "30-59", "60-89", "90+"}


def _ddl(table) -> str:
    return str(CreateTable(table).compile(dialect=postgresql.dialect()))


def test_schema_has_due_date_and_term():
    loan_ddl = _ddl(models.Loan.__table__)
    for col in ("term_months", "disbursement_date", "interest_rate",
                "monthly_installment", "maturity_date"):
        assert col in loan_ddl, f"loan missing column {col}: {loan_ddl}"

    sched_ddl = _ddl(models.RepaymentSchedule.__table__)
    for col in ("loan_id", "installment_no", "due_date", "principal_due",
                "interest_due", "status"):
        assert col in sched_ddl, f"repayment_schedule missing column {col}: {sched_ddl}"
    assert "UNIQUE" in sched_ddl.upper() or "uq_repayment_schedule" in sched_ddl


def test_amortize_annuity():
    principal, rate, term = 1000.0, 12.0, 12
    disbursement = date(2024, 1, 1)
    installment, rows = app._amortize(principal, rate, term, disbursement)

    assert len(rows) == term
    assert installment > 0
    assert rows[0][1] == "2024-02-01"          # disbursement + 1 month
    assert rows[-1][1] == "2025-01-01"          # maturity = disbursement + 12 months
    assert abs(sum(r[2] for r in rows) - principal) < 0.02  # principal fully amortized
    assert all(r[1] == date.fromisoformat(r[1]).isoformat() for r in rows)  # valid dates


def test_make_loan_unit_clean():
    loan, schedule, events = app._make_loan_unit("L-test", dirty_mode=None)
    for key in ("id", "amount", "currency", "origination_date", "borrower_id",
                "term_months", "disbursement_date", "interest_rate",
                "monthly_installment", "maturity_date"):
        assert key in loan, f"loan missing {key}"
    assert loan["term_months"] in constants.LOAN_TERMS
    assert len(schedule) == loan["term_months"]
    assert loan["maturity_date"] == schedule[-1]["due_date"]
    assert all(s["loan_id"] == "L-test" for s in schedule)
    assert all(s["status"] == constants.REPAYMENT_STATUS_SCHEDULED for s in schedule)
    assert any(e["event_type"] == "origination" for e in events)


def test_make_loan_unit_dirty_keeps_schedule_valid():
    for mode in constants.DIRTY_MODES:
        loan, schedule, _events = app._make_loan_unit("L-dirty", dirty_mode=mode)
        assert len(schedule) == loan["term_months"]
        # schedule itself always well-formed
        assert all(s["due_date"] and s["loan_id"] == "L-dirty" for s in schedule)
    # invalid_date specifically corrupts origination_date only
    loan, _, _ = app._make_loan_unit("L-inv", dirty_mode="invalid_date")
    assert loan["origination_date"] == "not-a-date"


def test_loan_book_unit_buckets():
    now = datetime(2026, 11, 5, 12, 0, 0, tzinfo=timezone.utc)
    for bucket, spec in app.NPL_BUCKETS.items():
        loan, schedule, events = app._loan_book_unit(now, bucket)
        dpd = spec["days_past_due"]

        # Every bucket's gold_bucket is one of the Gold accepted values.
        assert spec["gold_bucket"] in GOLD_BUCKETS

        # outstanding stays > 0: total paid < principal.
        total_paid = sum(e["amount"] for e in events if e["event_type"] == "payment")
        assert total_paid < loan["amount"], f"{bucket}: outstanding <= 0"

        overdue = [s for s in schedule if s["status"] == constants.REPAYMENT_STATUS_OVERDUE]
        paid = [s for s in schedule if s["status"] == constants.REPAYMENT_STATUS_PAID]
        assert len(paid) == spec["paid_installments"]

        if dpd == 0:
            # current loan: nothing overdue, latest payment anchors as_of == now.
            assert overdue == [], f"{bucket}: current loan has overdue instalments"
            assert max(e["occurred_at"] for e in events) == now
        else:
            oldest_overdue = min(date.fromisoformat(s["due_date"]) for s in overdue)
            actual_dpd = (now.date() - oldest_overdue).days
            assert actual_dpd == dpd, f"{bucket}: dpd {actual_dpd} != {dpd}"
            assert app._dpd_bucket(actual_dpd) == spec["gold_bucket"], bucket


def test_npl_buckets_match_gold_model():
    for spec in app.NPL_BUCKETS.values():
        assert spec["gold_bucket"] in GOLD_BUCKETS
    # _dpd_bucket is the pure mapping the Gold model implements.
    assert app._dpd_bucket(0) == "current"
    assert app._dpd_bucket(29) == "current"
    assert app._dpd_bucket(30) == "30-59"
    assert app._dpd_bucket(59) == "30-59"
    assert app._dpd_bucket(60) == "60-89"
    assert app._dpd_bucket(89) == "60-89"
    assert app._dpd_bucket(90) == "90+"
    assert app._dpd_bucket(200) == "90+"


def test_db_roundtrip_sqlite():
    """Prove the insert path (bulk_insert_mappings) writes the new columns + table."""
    from sqlalchemy import create_engine
    from sqlalchemy.orm import sessionmaker

    engine = create_engine("sqlite://")
    models.Base.metadata.create_all(engine)
    db = sessionmaker(bind=engine)()

    now = datetime(2026, 11, 5, 12, 0, 0, tzinfo=timezone.utc)
    loans, schedules, events = [], [], []
    for bucket in app.NPL_BUCKETS:
        loan, schedule, evs = app._loan_book_unit(now, bucket)
        loans.append(loan)
        schedules.extend(schedule)
        events.extend(evs)

    db.bulk_insert_mappings(models.Loan, loans)
    db.bulk_insert_mappings(models.RepaymentSchedule, schedules)
    db.bulk_insert_mappings(models.LoanEvent, events)
    db.commit()

    assert db.query(models.Loan).count() == len(app.NPL_BUCKETS)
    assert db.query(models.RepaymentSchedule).count() == len(schedules)
    assert db.query(models.LoanEvent).count() == len(events)

    # due_date / term / maturity round-trip with real values.
    row = db.query(models.RepaymentSchedule).first()
    assert row.due_date and row.loan_id and row.installment_no == 1
    loan_row = db.query(models.Loan).first()
    assert loan_row.term_months == constants.LOAN_BOOK_TERM
    assert loan_row.maturity_date
    db.close()


def _run_all():
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    for fn in fns:
        fn()
        print(f"  PASS  {fn.__name__}")
    print(f"\n{len(fns)} checks passed.")


if __name__ == "__main__":
    _run_all()
