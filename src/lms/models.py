"""SQLAlchemy models for the LMS source tables: borrower, loan, loan_event.

Deliberately NO foreign-key or check constraints: the source system is allowed
to emit exactly the defects the Silver dbt tests are meant to catch — orphan
borrower_id, NULL loan_id, negative amounts, invalid dates/currencies.
Referential integrity and data quality are enforced downstream by dbt, not by
the source. Column types mirror ``dbt/seeds/properties.yml`` (e.g. the
``origination_date`` is VARCHAR so an invalid value like "not-a-date" can be
stored and later trip the ``valid_date`` test).
"""
from __future__ import annotations

from sqlalchemy import Column, DateTime, Index, Numeric, String

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
