"""Database engine, session factory, and helpers for the LMS source service.

DATABASE_URL is read from the environment. Compose injects it as
``postgresql://user:pass@lms-postgres:5432/lms``; the URL is normalized to the
psycopg2 driver (``postgresql+psycopg2://``) because SQLAlchemy >= 2.1 defaults
the bare ``postgresql`` dialect to the psycopg v3 driver, while this service
targets psycopg2. ``postgres://`` is normalized as well.
"""
from __future__ import annotations

import os
import time

from sqlalchemy import create_engine, text
from sqlalchemy.orm import declarative_base, sessionmaker

DEFAULT_DATABASE_URL = "postgresql://lms:lms@localhost:5432/lms"


def _normalize_url(url: str) -> str:
    url = url.strip()
    if url.startswith("postgresql://") or url.startswith("postgres://"):
        # Force the psycopg2 driver explicitly: SQLAlchemy >= 2.1 defaults the
        # bare `postgresql` dialect to the psycopg v3 driver. The LMS service
        # targets psycopg2 per the project spec.
        _scheme, rest = url.split("://", 1)
        if "+" not in _scheme:
            url = "postgresql+psycopg2://" + rest
    return url


DATABASE_URL = _normalize_url(os.environ.get("DATABASE_URL", DEFAULT_DATABASE_URL))

engine = create_engine(DATABASE_URL, pool_pre_ping=True, future=True)
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False, future=True)
Base = declarative_base()


def wait_for_db(retries: int = 30, delay: float = 2.0) -> None:
    """Block until the database accepts a ``SELECT 1`` (or give up)."""
    last_exc: Exception | None = None
    for _attempt in range(1, retries + 1):
        try:
            with engine.connect() as conn:
                conn.execute(text("SELECT 1"))
            return
        except Exception as exc:  # noqa: BLE001 — any connectivity error
            last_exc = exc
            time.sleep(delay)
    raise RuntimeError(f"database not reachable after {retries} attempts") from last_exc


def get_db():
    """FastAPI dependency: yields a session and always closes it."""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
