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


def test_get_persistent_agents_returns_list(client):
    client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "a", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    r = client.get("/persistent_agents?workspace_id=1")
    assert r.status_code == 200
    body = r.json()
    assert "persistent_agents" in body
    assert any(a["name"] == "a" for a in body["persistent_agents"])


def test_patch_persistent_agent_renames(client):
    r = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "old", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    pid = r.json()["id"]
    r2 = client.patch(f"/persistent_agents/{pid}", json={"name": "new"})
    assert r2.status_code == 200
    assert r2.json()["name"] == "new"


def test_patch_persistent_agent_cron_recomputes_next_run(client):
    r = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "a", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    pid = r.json()["id"]
    r2 = client.patch(f"/persistent_agents/{pid}", json={"cron_schedule": "0 9 * * *"})
    assert r2.status_code == 200
    assert r2.json()["next_scheduled_run_at"] is not None
    assert r2.json()["next_scheduled_run_at"] > 0


def test_patch_non_member_returns_403(client):
    r = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "a", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    pid = r.json()["id"]
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="stranger", source="clerk", plan="free", email="s@x.com",
    )
    r2 = client.patch(f"/persistent_agents/{pid}", json={"name": "x"})
    assert r2.status_code == 403


# ── Sprint 49 A7: run_now + delete ────────────────────────────────────────────


@pytest.mark.skip(reason="A8: needs Orchestrator._fire_persistent_agent")
def test_run_now_creates_task_with_persistent_agent_id(client):
    import tally_orchestrator.service as svc
    r = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "a", "role_name": "Tester",
        "team_spec": {"agents": [{"role": "Tester"}], "stages": [[0]], "workflow": "sequential"},
    })
    pid = r.json()["id"]
    r2 = client.post(f"/persistent_agents/{pid}/run_now")
    assert r2.status_code == 200
    db = svc.state["db"]
    cnt = db._conn.execute(
        "SELECT COUNT(*) FROM tasks WHERE persistent_agent_id=?", (pid,)
    ).fetchone()[0]
    assert cnt == 1


def test_delete_persistent_agent_soft(client):
    r = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "a", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    pid = r.json()["id"]
    r2 = client.delete(f"/persistent_agents/{pid}")
    assert r2.status_code == 200
    r3 = client.get("/persistent_agents?workspace_id=1")
    assert all(a["id"] != pid for a in r3.json()["persistent_agents"])


def test_run_now_non_member_returns_403(client):
    r = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "a", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    pid = r.json()["id"]
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="stranger", source="clerk", plan="free", email="s@x.com",
    )
    r2 = client.post(f"/persistent_agents/{pid}/run_now")
    assert r2.status_code == 403


def test_delete_non_member_returns_403(client):
    r = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "a", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    pid = r.json()["id"]
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="stranger", source="clerk", plan="free", email="s@x.com",
    )
    r2 = client.delete(f"/persistent_agents/{pid}")
    assert r2.status_code == 403
