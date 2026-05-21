"""Sprint 49: persistent_agents HTTP routes."""
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


def test_post_persistent_agents_returns_201_and_id(client):
    r = client.post("/persistent_agents", json={
        "workspace_id": 1,
        "name": "nightly-tests",
        "role_name": "Tester",
        "team_spec": {"nodes": [{"id": "n1", "kind": "agent", "role": "Tester"}], "edges": [], "format": "nodes_v1"},
        "cron_schedule": "0 21 * * *",
    })
    assert r.status_code == 200
    body = r.json()
    assert body["name"] == "nightly-tests"
    assert body["id"] > 0
    assert body["cron_schedule"] == "0 21 * * *"


def test_post_persistent_agents_creates_scheduled_agent_channel(client):
    import tally_orchestrator.service as svc
    r = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "nightly", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    pid = r.json()["id"]
    db = svc.state["db"]
    row = db._conn.execute(
        "SELECT kind FROM channels WHERE persistent_agent_id=?", (pid,)
    ).fetchone()
    assert row is not None
    assert row[0] == "scheduled_agent"


def test_post_persistent_agents_generates_http_trigger_secret(client):
    """HTTP event triggers get auto-generated id + secret server-side."""
    r = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "wh", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
        "event_triggers": [{"kind": "http", "name": "github-pr"}],
    })
    assert r.status_code == 200
    triggers = r.json()["event_triggers"]
    assert len(triggers) == 1
    assert triggers[0]["kind"] == "http"
    assert triggers[0]["name"] == "github-pr"
    assert len(triggers[0].get("secret", "")) >= 16   # 32-hex (16 bytes)
    assert len(triggers[0].get("id", "")) >= 8


def test_post_persistent_agents_non_member_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="stranger", source="clerk", plan="free", email="s@x.com",
    )
    r = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "x", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    assert r.status_code == 403
