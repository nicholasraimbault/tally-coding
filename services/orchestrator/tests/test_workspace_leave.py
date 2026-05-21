"""Sprint 51: POST /workspaces/{id}/leave."""
import pytest
from fastapi.testclient import TestClient


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


def test_leave_non_owner_succeeds(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    # admin invites bob, then bob leaves
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="bob", source="clerk", plan="free", email="b@x.com",
    )
    r = client.post("/workspaces/1/leave")
    assert r.status_code == 200
    # bob no longer in members
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="admin", source="admin", plan="unlimited", email="admin@x.com",
    )
    members = client.get("/workspaces/1/members").json()["members"]
    assert not any(m.get("user_id") == "bob" for m in members)


def test_leave_owner_returns_400(client):
    """Admin is the owner of workspace 1 (from backfill).  Owner can't leave."""
    r = client.post("/workspaces/1/leave")
    assert r.status_code == 400


def test_leave_emits_audit(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="bob", source="clerk", plan="free", email="b@x.com",
    )
    client.post("/workspaces/1/leave")
    db = svc.state["db"]
    row = db._conn.execute(
        "SELECT actor_user_id FROM workspace_audit_log "
        "WHERE workspace_id=1 AND kind='member_left' ORDER BY id DESC LIMIT 1"
    ).fetchone()
    assert row is not None
    assert row[0] == "bob"


def test_leave_non_member_returns_404(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="stranger", source="clerk", plan="free", email="s@x.com",
    )
    r = client.post("/workspaces/1/leave")
    assert r.status_code == 404
