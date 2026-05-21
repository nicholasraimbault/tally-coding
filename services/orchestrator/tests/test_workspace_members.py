"""Sprint 50: Db helpers for workspace_members management."""
from tally_orchestrator.service import Db


def test_list_workspace_members(db: Db):
    wid = db.create_workspace(name="x", owner_user_id="alice")
    members = db.list_workspace_members(workspace_id=wid)
    user_ids = {m["user_id"] for m in members if m["member_kind"] == "human"}
    assert "alice" in user_ids


def test_add_workspace_member(db: Db):
    wid = db.create_workspace(name="x", owner_user_id="alice")
    db.add_workspace_member(workspace_id=wid, user_id="bob", role="member")
    members = db.list_workspace_members(workspace_id=wid)
    bobs = [m for m in members if m.get("user_id") == "bob"]
    assert len(bobs) == 1
    assert bobs[0]["role"] == "member"


def test_add_workspace_member_idempotent(db: Db):
    wid = db.create_workspace(name="x", owner_user_id="alice")
    db.add_workspace_member(workspace_id=wid, user_id="bob", role="member")
    db.add_workspace_member(workspace_id=wid, user_id="bob", role="member")
    members = db.list_workspace_members(workspace_id=wid)
    bobs = [m for m in members if m.get("user_id") == "bob"]
    assert len(bobs) == 1


def test_update_workspace_member_role(db: Db):
    wid = db.create_workspace(name="x", owner_user_id="alice")
    db.add_workspace_member(workspace_id=wid, user_id="bob", role="member")
    db.update_workspace_member_role(workspace_id=wid, user_id="bob", role="admin")
    members = db.list_workspace_members(workspace_id=wid)
    assert next(m for m in members if m["user_id"] == "bob")["role"] == "admin"


def test_remove_workspace_member(db: Db):
    wid = db.create_workspace(name="x", owner_user_id="alice")
    db.add_workspace_member(workspace_id=wid, user_id="bob", role="member")
    db.remove_workspace_member(workspace_id=wid, user_id="bob")
    members = db.list_workspace_members(workspace_id=wid)
    assert all(m.get("user_id") != "bob" for m in members)
