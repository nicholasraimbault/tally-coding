"""Sprint 52: CSV export of audit log."""
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


def test_export_returns_csv(client):
    """Sprint 52: GET /audit-log/export returns text/csv with a header row + at least one event row."""
    client.post("/workspaces/1/members", json={"user_id": "user_bob", "role": "member"})
    r = client.get("/workspaces/1/audit-log/export")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("text/csv")
    assert "filename=" in r.headers.get("content-disposition", "")
    lines = r.text.splitlines()
    # Header row
    assert "id" in lines[0]
    assert "kind" in lines[0]
    # At least one data row
    assert len(lines) >= 2


def test_export_applies_kind_filter(client):
    """Sprint 52: ?kind= filters the CSV rows."""
    client.post("/workspaces/1/members", json={"user_id": "user_bob", "role": "member"})  # member_invited
    client.delete("/workspaces/1/members/user_bob")  # member_removed
    r = client.get("/workspaces/1/audit-log/export?kind=member_removed")
    lines = r.text.splitlines()
    assert len(lines) == 2  # header + 1 row
    assert "member_removed" in lines[1]


def test_export_non_admin_returns_403(client):
    """Sprint 52: manager/member roles cannot export."""
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    client.post("/workspaces/1/members", json={"user_id": "user_bob", "role": "manager"})
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="user_bob", source="clerk", plan="free", email="b@x.com",
    )
    r = client.get("/workspaces/1/audit-log/export")
    assert r.status_code == 403
