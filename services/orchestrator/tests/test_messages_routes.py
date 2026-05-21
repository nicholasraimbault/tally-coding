"""Sprint 47: POST /channels/{id}/messages route."""
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


def _admin_general_channel_id(svc) -> int:
    """Helper: lookup admin workspace's #general channel id."""
    db = svc.state["db"]
    return db._conn.execute(
        "SELECT c.id FROM channels c "
        "JOIN workspaces w ON c.workspace_id=w.id "
        "WHERE w.owner_user_id='admin' AND c.kind='general' LIMIT 1"
    ).fetchone()[0]


def test_post_message_owner_succeeds(client):
    import tally_orchestrator.service as svc
    ch_id = _admin_general_channel_id(svc)
    r = client.post(f"/channels/{ch_id}/messages", json={"text": "hello world"})
    assert r.status_code == 200
    body = r.json()
    assert body["channel_id"] == ch_id
    assert body["author_kind"] == "human"
    assert body["author_user_id"] == "admin"
    assert body["kind"] == "text"
    assert json.loads(body["payload_json"])["text"] == "hello world"


def test_post_message_non_member_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    ch_id = _admin_general_channel_id(svc)
    # Override user to a stranger not in any workspace
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="stranger", source="clerk", plan="free", email="s@x.com",
    )
    r = client.post(f"/channels/{ch_id}/messages", json={"text": "hi"})
    assert r.status_code == 403
    assert "permission" in r.json()["detail"].lower() or "forbidden" in r.json()["detail"].lower()


def test_post_message_unknown_channel_returns_404(client):
    r = client.post("/channels/99999/messages", json={"text": "hi"})
    assert r.status_code == 404


def test_post_message_empty_text_returns_400(client):
    import tally_orchestrator.service as svc
    ch_id = _admin_general_channel_id(svc)
    r = client.post(f"/channels/{ch_id}/messages", json={"text": ""})
    assert r.status_code == 400


def test_post_message_text_persists_to_db(client):
    import tally_orchestrator.service as svc
    ch_id = _admin_general_channel_id(svc)
    r = client.post(f"/channels/{ch_id}/messages", json={"text": "persisted"})
    assert r.status_code == 200
    msg_id = r.json()["id"]
    row = svc.state["db"]._conn.execute(
        "SELECT payload_json FROM messages WHERE id=?", (msg_id,)
    ).fetchone()
    assert json.loads(row[0])["text"] == "persisted"


def test_get_messages_empty(client):
    import tally_orchestrator.service as svc
    ch_id = _admin_general_channel_id(svc)
    r = client.get(f"/channels/{ch_id}/messages")
    assert r.status_code == 200
    assert r.json() == {"messages": [], "channel_id": ch_id}


def test_get_messages_after_posts_in_reverse_chronological(client):
    import tally_orchestrator.service as svc
    ch_id = _admin_general_channel_id(svc)
    client.post(f"/channels/{ch_id}/messages", json={"text": "first"})
    client.post(f"/channels/{ch_id}/messages", json={"text": "second"})
    client.post(f"/channels/{ch_id}/messages", json={"text": "third"})

    r = client.get(f"/channels/{ch_id}/messages")
    assert r.status_code == 200
    msgs = r.json()["messages"]
    assert len(msgs) == 3
    # newest first
    texts = [json.loads(m["payload_json"])["text"] for m in msgs]
    assert texts == ["third", "second", "first"]


def test_get_messages_since_id(client):
    import tally_orchestrator.service as svc
    ch_id = _admin_general_channel_id(svc)
    r1 = client.post(f"/channels/{ch_id}/messages", json={"text": "a"})
    r2 = client.post(f"/channels/{ch_id}/messages", json={"text": "b"})
    r3 = client.post(f"/channels/{ch_id}/messages", json={"text": "c"})
    first_id = r1.json()["id"]

    r = client.get(f"/channels/{ch_id}/messages?since_id={first_id}")
    assert r.status_code == 200
    msgs = r.json()["messages"]
    assert len(msgs) == 2
    texts = sorted([json.loads(m["payload_json"])["text"] for m in msgs])
    assert texts == ["b", "c"]


def test_get_messages_non_member_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    ch_id = _admin_general_channel_id(svc)
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="stranger", source="clerk", plan="free", email="s@x.com",
    )
    r = client.get(f"/channels/{ch_id}/messages")
    assert r.status_code == 403
