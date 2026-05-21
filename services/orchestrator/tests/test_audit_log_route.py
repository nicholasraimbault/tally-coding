"""Sprint 51: GET /workspaces/{id}/audit-log."""
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


def test_get_audit_log_owner_can_read(client):
    # admin is owner of workspace 1 (backfill); invite bob to generate an event
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    r = client.get("/workspaces/1/audit-log")
    assert r.status_code == 200
    body = r.json()
    assert "entries" in body
    assert any(e["kind"] == "member_invited" for e in body["entries"])


def test_get_audit_log_admin_can_read(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    # promote bob to admin first (as owner=admin)
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "admin"})
    # now switch caller to bob
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="bob", source="clerk", plan="free", email="b@x.com",
    )
    r = client.get("/workspaces/1/audit-log")
    assert r.status_code == 200


def test_get_audit_log_manager_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "manager"})
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="bob", source="clerk", plan="free", email="b@x.com",
    )
    r = client.get("/workspaces/1/audit-log")
    assert r.status_code == 403


def test_get_audit_log_keyset_pagination(client):
    # generate 5 audit events via member invites
    for i in range(5):
        client.post("/workspaces/1/members", json={"user_id": f"u{i}", "role": "member"})
    r1 = client.get("/workspaces/1/audit-log?limit=2")
    assert r1.status_code == 200
    first = r1.json()["entries"]
    assert len(first) == 2
    r2 = client.get(f"/workspaces/1/audit-log?limit=2&before_id={first[-1]['id']}")
    assert r2.status_code == 200
    next_page = r2.json()["entries"]
    first_ids = {e["id"] for e in first}
    next_ids = {e["id"] for e in next_page}
    assert first_ids.isdisjoint(next_ids)
