"""Sprint 47 A10: WebSocket new_message event delivery."""
from __future__ import annotations

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
    svc.state["clerk_validator"] = None  # bearer-token path only

    from tally_orchestrator.clerk_auth import User as ClerkUser
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="admin", source="admin", plan="unlimited", email="admin@x.com",
    )
    yield TestClient(svc.app, raise_server_exceptions=True)
    svc.app.dependency_overrides.clear()


def _admin_general_channel_id(svc) -> int:
    db = svc.state["db"]
    return db._conn.execute(
        "SELECT c.id FROM channels c "
        "JOIN workspaces w ON c.workspace_id=w.id "
        "WHERE w.owner_user_id='admin' AND c.kind='general' LIMIT 1"
    ).fetchone()[0]


def test_ws_receives_new_message_event(client):
    """Posting a message via REST → existing /ws/notifications subscribers
    see a `new_message` event with channel_id + message_id."""
    import tally_orchestrator.service as svc
    ch_id = _admin_general_channel_id(svc)

    with client.websocket_connect("/ws/notifications?token=test-token") as ws:
        # Discard the hello frame.
        hello = ws.receive_json()
        assert hello["type"] == "hello"

        r = client.post(f"/channels/{ch_id}/messages", json={"text": "ws-test"})
        assert r.status_code == 200
        msg_id = r.json()["id"]

        # Read frames until we see new_message (in case other frames arrive first).
        for _ in range(5):
            msg = ws.receive_json()
            if msg.get("type") == "new_message":
                assert msg["channel_id"] == ch_id
                assert msg["message_id"] == msg_id
                return
        pytest.fail("did not receive new_message event within 5 frames")
