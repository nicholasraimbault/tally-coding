"""Sprint 48 A6: POST /tasks returns status='proposed' + inserts team_proposal message."""
import json
import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch, tmp_db_path):
    monkeypatch.setenv("ORCH_DB_PATH", tmp_db_path)
    monkeypatch.setenv("TALLY_API_TOKEN", "test-token")
    monkeypatch.setenv("REDPILL_API_KEY", "")  # disables architect call

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
    orchestrator.redpill_key = None  # no architect calls
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


def test_post_tasks_returns_proposed_status(client):
    r = client.post("/tasks", json={"description": "build a sorter"})
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "proposed"
    assert "id" in body
    assert "team_spec" in body


def test_post_tasks_inserts_team_proposal_message(client):
    import tally_orchestrator.service as svc
    r = client.post(
        "/tasks",
        json={
            "description": "build a sorter",
            "team_spec": {"agents": [{"role": "Coder"}]},
        },
    )
    assert r.status_code == 200
    body = r.json()
    task_id = body["id"]
    db = svc.state["db"]
    row = db._conn.execute(
        "SELECT m.kind, m.payload_json FROM messages m "
        "JOIN channels c ON m.channel_id=c.id "
        "JOIN workspaces w ON c.workspace_id=w.id "
        "WHERE w.owner_user_id='admin' AND c.kind='general' "
        "AND m.kind='team_proposal' ORDER BY m.id DESC LIMIT 1"
    ).fetchone()
    assert row is not None
    assert row[0] == "team_proposal"
    payload = json.loads(row[1])
    assert payload["task_id"] == task_id
    assert "team_spec" in payload


def test_post_tasks_no_dispatch_yet(client):
    """Status='proposed' means no agent has been dispatched."""
    import tally_orchestrator.service as svc
    r = client.post("/tasks", json={"description": "x"})
    assert r.status_code == 200
    body = r.json()
    task_id = body["id"]
    db = svc.state["db"]
    cnt = db._conn.execute(
        "SELECT COUNT(*) FROM agents WHERE task_id=?", (task_id,)
    ).fetchone()[0]
    assert cnt == 0, f"expected no dispatched agents while proposed; got {cnt}"
