"""Sprint 52: audit log filter params on Db.list_audit_log."""
import time
import pytest

from tally_orchestrator.service import Db


@pytest.fixture
def db(tmp_db_path):
    d = Db(tmp_db_path)
    yield d


def _seed(db: Db, workspace_id: int = 1) -> None:
    db.audit_log(workspace_id=workspace_id, actor_user_id="alice", kind="workspace_created", payload={})
    db.audit_log(workspace_id=workspace_id, actor_user_id="alice", kind="member_invited", payload={})
    db.audit_log(workspace_id=workspace_id, actor_user_id="bob", kind="channel_created", payload={})
    db.audit_log(workspace_id=workspace_id, actor_user_id="bob", kind="channel_archived", payload={})


def test_filter_by_kind(db: Db):
    _seed(db)
    rows = db.list_audit_log(workspace_id=1, kind="channel_created")
    assert len(rows) == 1
    assert rows[0]["kind"] == "channel_created"


def test_filter_by_actor(db: Db):
    _seed(db)
    rows = db.list_audit_log(workspace_id=1, actor_user_id="bob")
    assert len(rows) == 2
    assert all(r["actor_user_id"] == "bob" for r in rows)


def test_filter_combo_kind_and_actor(db: Db):
    _seed(db)
    rows = db.list_audit_log(workspace_id=1, kind="channel_archived", actor_user_id="bob")
    assert len(rows) == 1


def test_filter_since(db: Db):
    db.audit_log(workspace_id=1, actor_user_id="alice", kind="old", payload={})
    time.sleep(0.02)
    cutoff = time.time()
    time.sleep(0.02)
    db.audit_log(workspace_id=1, actor_user_id="alice", kind="new", payload={})
    rows = db.list_audit_log(workspace_id=1, since=cutoff)
    kinds = {r["kind"] for r in rows}
    assert "new" in kinds
    assert "old" not in kinds


def test_filter_until(db: Db):
    db.audit_log(workspace_id=1, actor_user_id="alice", kind="early", payload={})
    time.sleep(0.02)
    cutoff = time.time()
    time.sleep(0.02)
    db.audit_log(workspace_id=1, actor_user_id="alice", kind="late", payload={})
    rows = db.list_audit_log(workspace_id=1, until=cutoff)
    kinds = {r["kind"] for r in rows}
    assert "early" in kinds
    assert "late" not in kinds
