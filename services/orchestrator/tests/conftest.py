# services/orchestrator/tests/conftest.py
"""Shared pytest fixtures for orchestrator tests."""
from __future__ import annotations

from pathlib import Path

import pytest


@pytest.fixture
def tmp_db_path(tmp_path: Path) -> str:
    """Temp SQLite path; cleaned up at end of test."""
    return str(tmp_path / "test.db")


@pytest.fixture
def db(tmp_db_path: str):
    """Fresh Db instance backed by a temp file."""
    from tally_orchestrator.service import Db
    return Db(tmp_db_path)


@pytest.fixture
def freeze_time(monkeypatch):
    """Patch time.time() in the service module to return a fixed value."""
    fixed = [1_700_000_000.0]
    def _set(t: float) -> None:
        fixed[0] = t
    import tally_orchestrator.service as svc
    monkeypatch.setattr(svc.time, "time", lambda: fixed[0])
    return _set


@pytest.fixture(autouse=True)
def _isolate_env(monkeypatch):
    """Clear env vars that would alter behavior across tests."""
    for var in ("STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET", "TALLY_PUSH_JITTER_MAX_S"):
        monkeypatch.delenv(var, raising=False)
