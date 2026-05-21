"""Sprint 50: Db helpers for workspace_members management + GET /workspaces/{wid}/members route."""
import pytest
from fastapi.testclient import TestClient

from tally_orchestrator.service import Db


# ── HTTP route fixture ─────────────────────────────────────────────────────────


@pytest.fixture
def client(monkeypatch, tmp_db_path):
    monkeypatch.setenv("ORCH_DB_PATH", tmp_db_path)
    monkeypatch.setenv("TALLY_API_TOKEN", "test-token")
    monkeypatch.setenv("REDPILL_API_KEY", "")
    import importlib
    import tally_orchestrator.service as svc
    importlib.reload(svc)

    db = svc.Db(tmp_db_path)
    event_bus = svc.EventBus()
    orchestrator = svc.Orchestrator(
        tally_url="http://localhost:9999",
        identity_path=tmp_db_path + ".orch.key",
        mls_state_base_dir=tmp_db_path + ".mls",
        db=db,
        event_bus=event_bus,
    )
    orchestrator.redpill_key = None
    svc.state["db"] = db
    svc.state["orchestrator"] = orchestrator
    svc.state["event_bus"] = event_bus
    svc.state["api_token"] = "test-token"
    svc.state["pool_ready"] = True
    svc.state["pool_status"] = {"target_size": 0, "joined": 0, "last_error": None}

    from tally_orchestrator.clerk_auth import User as ClerkUser
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="admin", source="admin", plan="unlimited", email="admin@x.com",
    )
    yield TestClient(svc.app)
    svc.app.dependency_overrides.clear()


# ── GET /workspaces/{wid}/members route tests ──────────────────────────────────


def test_get_workspace_members_returns_list(client):
    r = client.get("/workspaces/1/members")
    assert r.status_code == 200
    body = r.json()
    assert "members" in body
    humans = [m for m in body["members"] if m["member_kind"] == "human"]
    assert any(m["user_id"] == "admin" for m in humans)


def test_get_workspace_members_non_member_returns_empty(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="stranger", source="clerk", plan="free", email="s@x.com",
    )
    r = client.get("/workspaces/1/members")
    assert r.status_code == 200
    assert r.json()["members"] == []


# ── Db-level unit tests ────────────────────────────────────────────────────────


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
