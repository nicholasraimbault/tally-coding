"""Sprint 52: workspace ownership transfer."""
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


def test_owner_can_transfer_to_existing_member(client):
    import tally_orchestrator.service as svc
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    r = client.post("/workspaces/1/transfer-ownership", json={"new_owner_user_id": "bob"})
    assert r.status_code == 200
    db = svc.state["db"]
    # workspaces.owner_user_id updated
    owner = db._conn.execute("SELECT owner_user_id FROM workspaces WHERE id=1").fetchone()[0]
    assert owner == "bob"
    # bob is now 'owner' in workspace_members
    bob_role = db._conn.execute(
        "SELECT role FROM workspace_members WHERE workspace_id=1 AND user_id='bob'"
    ).fetchone()[0]
    assert bob_role == "owner"
    # admin (old owner) demoted to 'admin'
    admin_role = db._conn.execute(
        "SELECT role FROM workspace_members WHERE workspace_id=1 AND user_id='admin'"
    ).fetchone()[0]
    assert admin_role == "admin"


def test_transfer_to_non_member_returns_404(client):
    r = client.post("/workspaces/1/transfer-ownership", json={"new_owner_user_id": "nobody"})
    assert r.status_code == 404


def test_non_owner_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="bob", source="clerk", plan="free", email="b@x.com",
    )
    r = client.post("/workspaces/1/transfer-ownership", json={"new_owner_user_id": "bob"})
    assert r.status_code == 403


def test_self_transfer_returns_400(client):
    r = client.post("/workspaces/1/transfer-ownership", json={"new_owner_user_id": "admin"})
    assert r.status_code == 400


def test_transfer_emits_audit(client):
    import tally_orchestrator.service as svc
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    client.post("/workspaces/1/transfer-ownership", json={"new_owner_user_id": "bob"})
    db = svc.state["db"]
    row = db._conn.execute(
        "SELECT kind FROM workspace_audit_log "
        "WHERE workspace_id=1 AND kind='workspace_ownership_transferred' "
        "ORDER BY id DESC LIMIT 1"
    ).fetchone()
    assert row is not None
