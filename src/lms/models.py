"""SQLAlchemy models for the LMS source tables: borrower, loan, loan_event,
repayment_schedule.

Deliberately NO foreign-key or check constraints: the source system is allowed
to emit exactly the defects the Silver dbt tests are meant to catch — orphan
borrower_id, NULL loan_id, negative amounts, invalid dates/currencies.
Referential integrity and data quality are enforced downstream by dbt, not by
the source. Column types mirror ``dbt/seeds/properties.yml`` (e.g. the
``origination_date`` is VARCHAR so an invalid value like "not-a-date" can be
stored and later trip the ``valid_date`` test).

Repayment contract (NPL) — added so days-past-due is derived from a REAL due
date, not a 365-day term assumption:

  * ``loan.amount``        is the principal (existing column; no separate
                           ``principal_amount`` — kept non-breaking).
  * ``loan.term_months``   variable term, default 12.
  * ``loan.disbursement_date``  ISO ``YYYY-MM-DD`` (VARCHAR, same convention as
                           ``origination_date`` so Debezium/dbt don't have to
                           decode a Postgres DATE → int32).
  * ``loan.interest_rate`` annual interest rate in percent (e.g. 12.00 = 12%).
  * ``loan.monthly_installment`` the equal monthly annuity (PMT).
  * ``loan.maturity_date`` the final contractual due date (= last schedule row).
  * ``repayment_schedule`` one row per instalment with its own ``due_date``,
    ``principal_due``/``interest_due`` and a ``status``
    (``scheduled`` / ``paid`` / ``overdue``). Gold derives days-past-due from
    ``repayment_schedule.due_date``.
"""
from __future__ import annotations

from sqlalchemy import (
    Column,
    DateTime,
    Index,
    Integer,
    Numeric,
    String,
    UniqueConstraint,
)

from db import Base


class Borrower(Base):
    __tablename__ = "borrower"

    id = Column(String(32), primary_key=True)
    full_name = Column(String(255), nullable=False)

    def __repr__(self) -> str:  # pragma: no cover
        return f"<Borrower {self.id}>"


class Loan(Base):
    __tablename__ = "loan"

    id = Column(String(32), primary_key=True)
    amount = Column(Numeric(18, 2), nullable=False)
    currency = Column(String(8), nullable=False)
    # VARCHAR by design (see module docstring) so invalid dates can be stored.
    origination_date = Column(String(16), nullable=False)
    borrower_id = Column(String(32), nullable=False)

    # ── Repayment contract (NPL) ─────────────────────────────────────────────
    term_months = Column(Integer, nullable=False, server_default="12")
    # ISO YYYY-MM-DD (VARCHAR) — see module docstring for the DATE-vs-VARCHAR call.
    disbursement_date = Column(String(16), nullable=False)
    # Annual interest rate in percent (e.g. 12.00 = 12%).
    interest_rate = Column(Numeric(5, 2), nullable=False)
    # Equal monthly annuity (PMT) for the amortizing schedule.
    monthly_installment = Column(Numeric(18, 2), nullable=False)
    # Final contractual due date (= last repayment_schedule.due_date).
    maturity_date = Column(String(16), nullable=False)

    __table_args__ = (Index("ix_loan_borrower_id", "borrower_id"),)

    def __repr__(self) -> str:  # pragma: no cover
        return f"<Loan {self.id} {self.amount} {self.currency}>"


class LoanEvent(Base):
    __tablename__ = "loan_event"

    id = Column(String(32), primary_key=True)
    # Nullable on purpose: a NULL loan_id is one of the engineered dirty modes.
    loan_id = Column(String(32), nullable=True)
    event_type = Column(String(32), nullable=False)
    # Optional enrichment (payment / disbursement amounts). Ignored by dbt's
    # loan_event passthrough model, which selects id/loan_id/event_type/occurred_at.
    amount = Column(Numeric(18, 2), nullable=True)
    occurred_at = Column(DateTime(timezone=True), nullable=False)

    __table_args__ = (Index("ix_loan_event_loan_id", "loan_id"),)

    def __repr__(self) -> str:  # pragma: no cover
        return f"<LoanEvent {self.id} {self.event_type}>"


class RepaymentSchedule(Base):
    __tablename__ = "repayment_schedule"

    id = Column(String(32), primary_key=True)
    # Nullable=False here (unlike loan_event.loan_id): the schedule is real
    # contractual data, never part of an engineered dirty mode.
    loan_id = Column(String(32), nullable=False)
    installment_no = Column(Integer, nullable=False)
    # ISO YYYY-MM-DD (VARCHAR) — the REAL due date the Gold NPL model anchors on.
    due_date = Column(String(16), nullable=False)
    principal_due = Column(Numeric(18, 2), nullable=False)
    interest_due = Column(Numeric(18, 2), nullable=False)
    # scheduled (future) / paid / overdue (past due date, unpaid).
    status = Column(String(16), nullable=False)

    __table_args__ = (
        UniqueConstraint("loan_id", "installment_no", name="uq_repayment_schedule_loan_inst"),
        Index("ix_repayment_schedule_loan_id", "loan_id"),
        Index("ix_repayment_schedule_due_date", "due_date"),
    )

    def __repr__(self) -> str:  # pragma: no cover
        return f"<RepaymentSchedule {self.loan_id} #{self.installment_no} {self.due_date}>"
