"""Sprint 50: custom channel creation + channel_member CRUD."""
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


def test_post_custom_channel_returns_id(client):
    r = client.post("/channels", json={
        "workspace_id": 1, "kind": "custom", "name": "code-review",
        "members": [{"kind": "human", "id": "admin"}, {"kind": "tally"}],
    })
    assert r.status_code == 200
    body = r.json()
    assert body["kind"] == "custom"
    assert body["name"] == "code-review"


def test_post_custom_channel_inserts_all_members(client):
    import tally_orchestrator.service as svc
    pa = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "linter", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    pid = pa.json()["id"]
    r = client.post("/channels", json={
        "workspace_id": 1, "kind": "custom", "name": "ops",
        "members": [
            {"kind": "human", "id": "admin"},
            {"kind": "tally"},
            {"kind": "persistent_agent", "id": str(pid)},
        ],
    })
    ch_id = r.json()["id"]
    db = svc.state["db"]
    members = db._conn.execute(
        "SELECT member_kind, user_id, persistent_agent_id FROM channel_members WHERE channel_id=?",
        (ch_id,),
    ).fetchall()
    kinds = {m[0] for m in members}
    assert kinds == {"human", "tally", "persistent_agent"}


def test_post_custom_channel_non_admin_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="bob", source="clerk", plan="free", email="b@x.com",
    )
    r = client.post("/channels", json={
        "workspace_id": 1, "kind": "custom", "name": "x", "members": [],
    })
    assert r.status_code == 403


def test_post_custom_channel_non_custom_kind_returns_400(client):
    r = client.post("/channels", json={
        "workspace_id": 1, "kind": "general", "name": "x", "members": [],
    })
    assert r.status_code == 400


def test_add_channel_member(client):
    r = client.post("/channels", json={
        "workspace_id": 1, "kind": "custom", "name": "x",
        "members": [{"kind": "human", "id": "admin"}],
    })
    ch_id = r.json()["id"]
    r2 = client.post(f"/channels/{ch_id}/members", json={"member_kind": "human", "user_id": "bob"})
    assert r2.status_code == 200


def test_remove_channel_member(client):
    r = client.post("/channels", json={
        "workspace_id": 1, "kind": "custom", "name": "x",
        "members": [{"kind": "human", "id": "admin"}, {"kind": "human", "id": "bob"}],
    })
    ch_id = r.json()["id"]
    r2 = client.delete(f"/channels/{ch_id}/members/bob")
    assert r2.status_code == 200


def test_add_channel_member_non_custom_returns_400(client):
    """Cannot add members directly to general/task/scheduled_agent channels."""
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    # Find admin's #general channel
    ch_id = db._conn.execute(
        "SELECT c.id FROM channels c JOIN workspaces w ON c.workspace_id=w.id "
        "WHERE w.owner_user_id='admin' AND c.kind='general' LIMIT 1"
    ).fetchone()[0]
    r = client.post(f"/channels/{ch_id}/members", json={"member_kind": "human", "user_id": "bob"})
    assert r.status_code == 400
