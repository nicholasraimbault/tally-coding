"""Sprint 50: PATCH /workspaces/{id} for branding/settings."""
import json
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


def test_patch_workspace_merges_settings(client):
    import tally_orchestrator.service as svc
    r = client.post("/workspaces", json={"name": "x"})
    assert r.status_code == 200, r.json()
    wid = r.json()["id"]
    r2 = client.patch(f"/workspaces/{wid}", json={"name": "renamed", "settings": {"icon_url": "https://x/y.png"}})
    assert r2.status_code == 200
    db = svc.state["db"]
    row = db._conn.execute(
        "SELECT name, settings_json FROM workspaces WHERE id=?", (wid,)
    ).fetchone()
    assert row[0] == "renamed"
    settings = json.loads(row[1])
    assert settings["icon_url"] == "https://x/y.png"


def test_patch_workspace_non_owner_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    r = client.post("/workspaces", json={"name": "x"})
    assert r.status_code == 200, r.json()
    wid = r.json()["id"]
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="stranger", source="clerk", plan="free", email="s@x.com",
    )
    r2 = client.patch(f"/workspaces/{wid}", json={"name": "hacked"})
    assert r2.status_code == 403
