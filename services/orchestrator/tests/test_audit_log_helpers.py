"""Sprint 51: Db helpers for audit log."""
from tally_orchestrator.service import Db


def test_audit_log_inserts_row(db: Db):
    db.audit_log(
        workspace_id=1, actor_user_id="admin",
        kind="workspace_created", payload={"name": "test"},
    )
    row = db._conn.execute(
        "SELECT kind, actor_user_id, payload_json FROM workspace_audit_log WHERE workspace_id=1 ORDER BY id DESC LIMIT 1"
    ).fetchone()
    assert row[0] == "workspace_created"
    assert row[1] == "admin"


def test_audit_log_system_actor(db: Db):
    db.audit_log(
        workspace_id=1, actor_user_id=None, actor_kind="system",
        kind="persistent_agent_auto_paused", payload={"agent_id": 5},
    )
    row = db._conn.execute(
        "SELECT actor_user_id, actor_kind FROM workspace_audit_log WHERE workspace_id=1 ORDER BY id DESC LIMIT 1"
    ).fetchone()
    assert row[0] == "system"
    assert row[1] == "system"


def test_list_audit_log_returns_newest_first(db: Db):
    for i in range(3):
        db.audit_log(workspace_id=1, actor_user_id="admin", kind=f"test_{i}", payload={})
    rows = db.list_audit_log(workspace_id=1, limit=10)
    kinds = [r["kind"] for r in rows[:3]]
    # newest first
    assert kinds == ["test_2", "test_1", "test_0"]


def test_list_audit_log_keyset_pagination(db: Db):
    for i in range(5):
        db.audit_log(workspace_id=1, actor_user_id="admin", kind=f"e{i}", payload={})
    first = db.list_audit_log(workspace_id=1, limit=2)
    assert len(first) == 2
    next_page = db.list_audit_log(workspace_id=1, limit=2, before_id=first[-1]["id"])
    first_ids = {e["id"] for e in first}
    next_ids = {e["id"] for e in next_page}
    assert first_ids.isdisjoint(next_ids)
