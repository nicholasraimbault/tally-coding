"""Sprint 50: workspaces.deleted_at column."""
from tally_orchestrator.service import Db


def test_workspaces_deleted_at_column(db: Db):
    cols = {r[1] for r in db._conn.execute("PRAGMA table_info(workspaces)").fetchall()}
    assert "deleted_at" in cols
