#!/usr/bin/env python3
"""Idempotent schema + seed for the LMS source database.

Creates the four source tables (borrower, loan, loan_event, repayment_schedule)
if missing and seeds the four valid borrowers (B-1001..B-1004). Safe to run
repeatedly: ``CREATE TABLE IF NOT EXISTS`` + ``INSERT ... ON CONFLICT DO
NOTHING``.

Usage:
    python seed.py
"""
from __future__ import annotations

from sqlalchemy.dialects.postgresql import insert as pg_insert

import constants
import models  # noqa: F401  (registers tables on Base.metadata)
from db import Base, SessionLocal, engine, wait_for_db


def create_schema() -> None:
    Base.metadata.create_all(bind=engine)


def seed_borrowers() -> int:
    rows = [{"id": bid, "full_name": name} for bid, name in constants.SEED_BORROWERS]
    with SessionLocal() as db:
        stmt = (
            pg_insert(models.Borrower)
            .values(rows)
            .on_conflict_do_nothing(index_elements=["id"])
        )
        db.execute(stmt)
        db.commit()
    return len(rows)


def main() -> None:
    print("lms-api seed: waiting for database...", flush=True)
    wait_for_db()
    create_schema()
    seeded = seed_borrowers()
    print(
        f"lms-api seed: schema ensured (borrower, loan, loan_event, repayment_schedule); "
        f"{seeded} borrowers upserted",
        flush=True,
    )


if __name__ == "__main__":
    main()
