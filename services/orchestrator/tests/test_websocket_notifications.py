"""Sprint 46 A17: /ws/notifications WebSocket endpoint."""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch, tmp_db_path):
    # Set env vars before the module-level config picks them up.
    monkeypatch.setenv("ORCH_DB_PATH", tmp_db_path)
    monkeypatch.setenv("TALLY_API_TOKEN", "test-token")
    monkeypatch.setenv("REDPILL_API_KEY", "")  # disables architect call

    # Reload so module-level singletons use the patched env.
    import importlib
    import tally_orchestrator.service as svc
    importlib.reload(svc)

    # Manually populate state — skip the lifespan (which would try to
    # provision real CVM workers and block indefinitely).
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
    # No Clerk validator needed — tests use the bearer-token path.
    svc.state["clerk_validator"] = None

    yield TestClient(svc.app, raise_server_exceptions=True)

    svc.app.dependency_overrides.clear()


def test_websocket_handshake_accepts_with_token(client):
    """Valid bearer token → WebSocket accepted, hello received."""
    with client.websocket_connect("/ws/notifications?token=test-token") as ws:
        msg = ws.receive_json()
        assert msg["type"] == "hello"


def test_websocket_rejects_without_token(client):
    """No token → connection closed with 4401."""
    with pytest.raises(Exception):
        with client.websocket_connect("/ws/notifications"):
            pass  # expect rejection before we read anything


async def test_websocket_receives_notification_signal(client, monkeypatch):
    """fan_out_push delivers new_notification to registered WebSocket."""
    import tally_orchestrator.service as svc
    from tally_orchestrator.notifications import insert_notification, fan_out_push

    # Zero jitter so fan_out_push delivers synchronously within the test.
    monkeypatch.setenv("TALLY_PUSH_JITTER_MAX_S", "0")

    with client.websocket_connect("/ws/notifications?token=test-token") as ws:
        ws.receive_json()  # discard hello

        db = svc.state["db"]
        nid = insert_notification(db, "admin", kind="test")
        await fan_out_push(db, "admin", nid)

        msg = ws.receive_json()
        assert msg["type"] == "new_notification"
        assert msg["id"] == nid
