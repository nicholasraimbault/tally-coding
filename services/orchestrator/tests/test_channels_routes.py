"""Sprint 47: GET /channels + POST /channels/{id}/members routes."""
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


def test_list_channels_returns_general_and_backlog(client):
    r = client.get("/channels?workspace_id=1")
    assert r.status_code == 200
    body = r.json()
    kinds = {c["kind"] for c in body["channels"]}
    assert {"general", "backlog"}.issubset(kinds)


def test_list_channels_unknown_workspace_returns_empty(client):
    r = client.get("/channels?workspace_id=99999")
    assert r.status_code == 200
    assert r.json()["channels"] == []


def test_list_channels_filters_archived(client):
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    # Insert an archived task channel with a channel_members row so the
    # admin user has visibility into it (task channels need explicit membership).
    cur = db._conn.execute(
        "INSERT INTO channels (workspace_id, kind, name, created_at, archived_at) "
        "VALUES (1, 'task', 'archived-task', 0, 100)"
    )
    ch_id = cur.lastrowid
    db._conn.execute(
        "INSERT INTO channel_members (channel_id, member_kind, user_id, joined_at) "
        "VALUES (?, 'human', 'admin', 0)",
        (ch_id,),
    )
    r = client.get("/channels?workspace_id=1")
    assert r.status_code == 200
    archived = [c for c in r.json()["channels"] if c["archived_at"] is not None]
    assert len(archived) == 0  # filtered by default
    r2 = client.get("/channels?workspace_id=1&include_archived=true")
    assert r2.status_code == 200
    archived = [c for c in r2.json()["channels"] if c["archived_at"] is not None]
    assert len(archived) >= 1
