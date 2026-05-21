"""Sprint 51: workspace_audit_log table."""
from tally_orchestrator.service import Db


def test_workspace_audit_log_table_present(db: Db):
    row = db._conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='workspace_audit_log'"
    ).fetchone()
    assert row is not None


def test_workspace_audit_log_columns(db: Db):
    cols = {r[1] for r in db._conn.execute("PRAGMA table_info(workspace_audit_log)").fetchall()}
    expected = {
        "id", "workspace_id", "actor_user_id", "actor_kind", "kind",
        "target_kind", "target_id", "payload_json", "created_at",
    }
    assert expected.issubset(cols)


def test_workspace_audit_log_indexes(db: Db):
    idxs = {r[1] for r in db._conn.execute("PRAGMA index_list('workspace_audit_log')").fetchall()}
    assert "idx_audit_log_workspace" in idxs
    assert "idx_audit_log_actor" in idxs
