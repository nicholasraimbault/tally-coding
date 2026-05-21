"""Sprint 49: POST /channels/dm route."""
import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch, tmp_db_path):
    monkeypatch.setenv("ORCH_DB_PATH", tmp_db_path)
    monkeypatch.setenv("TALLY_API_TOKEN", "test-token")
    monkeypatch.setenv("REDPILL_API_KEY", "")
    monkeypatch.setenv("TALLY_TEST_MODE", "1")
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


def test_post_dm_tally_creates_channel(client):
    r = client.post("/channels/dm", json={"target_kind": "tally"})
    assert r.status_code == 200
    body = r.json()
    assert body["kind"] == "dm"
    assert body["id"] > 0


def test_post_dm_tally_idempotent(client):
    r1 = client.post("/channels/dm", json={"target_kind": "tally"})
    r2 = client.post("/channels/dm", json={"target_kind": "tally"})
    assert r1.json()["id"] == r2.json()["id"]


def test_post_dm_persistent_agent(client):
    pa = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "x", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    pid = pa.json()["id"]
    r = client.post("/channels/dm", json={"target_kind": "persistent_agent", "target_id": str(pid)})
    assert r.status_code == 200
    body = r.json()
    assert body["kind"] == "dm"


def test_post_dm_invalid_target_kind_returns_400(client):
    r = client.post("/channels/dm", json={"target_kind": "alien"})
    assert r.status_code == 400
