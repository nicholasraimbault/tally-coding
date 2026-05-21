"""Sprint 51: DELETE /workspaces/{id}."""
import pytest
from fastapi.testclient import TestClient


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


# ── DELETE /workspaces/{wid} tests ────────────────────────────────────────────


def test_delete_workspace_owner_can_delete(client):
    r = client.post("/workspaces", json={"name": "doomed"})
    wid = r.json()["id"]
    r2 = client.delete(f"/workspaces/{wid}")
    assert r2.status_code == 200
    # Soft-deleted: not in /me/workspaces
    r3 = client.get("/me/workspaces")
    assert not any(w["id"] == wid for w in r3.json()["workspaces"])


def test_delete_workspace_non_owner_returns_403_or_404(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    r = client.post("/workspaces", json={"name": "x"})
    wid = r.json()["id"]
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="stranger", source="clerk", plan="free", email="s@x.com",
    )
    r2 = client.delete(f"/workspaces/{wid}")
    assert r2.status_code in (403, 404)


def test_delete_workspace_emits_audit(client):
    import tally_orchestrator.service as svc
    r = client.post("/workspaces", json={"name": "audit-me"})
    wid = r.json()["id"]
    client.delete(f"/workspaces/{wid}")
    db = svc.state["db"]
    row = db._conn.execute(
        "SELECT kind FROM workspace_audit_log "
        "WHERE workspace_id=? AND kind='workspace_deleted' ORDER BY id DESC LIMIT 1",
        (wid,),
    ).fetchone()
    assert row is not None
