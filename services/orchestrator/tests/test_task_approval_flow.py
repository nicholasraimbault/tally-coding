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


def test_approve_transitions_to_pending(client):
    import tally_orchestrator.service as svc
    r = client.post("/tasks", json={"description": "x"})
    body = r.json()
    task_id = body.get("task_id") or body.get("id")
    r2 = client.post(f"/tasks/{task_id}/approve")
    assert r2.status_code == 200
    db = svc.state["db"]
    status = db._conn.execute("SELECT status FROM tasks WHERE id=?", (task_id,)).fetchone()[0]
    assert status == "pending"


def test_approve_creates_task_channel(client):
    import tally_orchestrator.service as svc
    r = client.post("/tasks", json={"description": "x"})
    body = r.json()
    task_id = body.get("task_id") or body.get("id")
    db = svc.state["db"]
    pre = db._conn.execute("SELECT id FROM channels WHERE task_id=?", (task_id,)).fetchone()
    assert pre is None
    client.post(f"/tasks/{task_id}/approve")
    post = db._conn.execute("SELECT id, kind FROM channels WHERE task_id=?", (task_id,)).fetchone()
    assert post is not None
    assert post[1] == "task"


def test_approve_returns_409_on_repeat(client):
    r = client.post("/tasks", json={"description": "x"})
    body = r.json()
    task_id = body.get("task_id") or body.get("id")
    r1 = client.post(f"/tasks/{task_id}/approve")
    assert r1.status_code == 200
    r2 = client.post(f"/tasks/{task_id}/approve")
    assert r2.status_code == 409


def test_approve_non_owner_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    r = client.post("/tasks", json={"description": "x"})
    body = r.json()
    task_id = body.get("task_id") or body.get("id")
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="stranger", source="clerk", plan="free", email="s@x.com",
    )
    r2 = client.post(f"/tasks/{task_id}/approve")
    assert r2.status_code == 403


def test_approve_unknown_task_returns_404(client):
    r = client.post("/tasks/nonexistent/approve")
    assert r.status_code == 404


def test_patch_team_spec_updates(client):
    import tally_orchestrator.service as svc
    import json as _json
    r = client.post("/tasks", json={"description": "x"})
    body = r.json()
    task_id = body.get("task_id") or body.get("id")
    new_spec = {"nodes": [{"id": "n1", "kind": "agent", "role": "Tester"}], "edges": [], "format": "nodes_v1"}
    r2 = client.patch(f"/tasks/{task_id}/team_spec", json={"team_spec": new_spec})
    assert r2.status_code == 200
    db = svc.state["db"]
    stored = _json.loads(db._conn.execute("SELECT team_spec FROM tasks WHERE id=?", (task_id,)).fetchone()[0])
    assert stored["nodes"][0]["role"] == "Tester"


def test_patch_team_spec_409_after_approve(client):
    r = client.post("/tasks", json={"description": "x"})
    body = r.json()
    task_id = body.get("task_id") or body.get("id")
    client.post(f"/tasks/{task_id}/approve")
    r2 = client.patch(f"/tasks/{task_id}/team_spec", json={"team_spec": {"nodes": [], "edges": []}})
    assert r2.status_code == 409


def test_patch_team_spec_non_owner_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    r = client.post("/tasks", json={"description": "x"})
    body = r.json()
    task_id = body.get("task_id") or body.get("id")
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="stranger", source="clerk", plan="free", email="s@x.com",
    )
    r2 = client.patch(f"/tasks/{task_id}/team_spec", json={"team_spec": {"nodes": [], "edges": []}})
    assert r2.status_code == 403
