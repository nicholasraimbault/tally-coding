"""Sprint 46 A15: REST endpoints for notifications + notification_rules + push devices."""
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

    # Manually populate state so we don't run the lifespan (which would
    # try to provision real CVM workers and block indefinitely).
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

    # Override require_user for every test in this module.
    from tally_orchestrator.clerk_auth import User as ClerkUser
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="u1", source="clerk", plan="pro_beta", email="u1@x.com",
    )

    yield TestClient(svc.app, raise_server_exceptions=True)

    svc.app.dependency_overrides.clear()


def test_get_notifications_empty(client):
    """Empty inbox returns a 200 with an empty list and next_since_id=0."""
    r = client.get("/notifications")
    assert r.status_code == 200
    assert r.json() == {"notifications": [], "next_since_id": 0}


def test_post_dismiss_notification(client):
    """Insert a notification via helper, dismiss it, verify it disappears."""
    import tally_orchestrator.service as svc
    from tally_orchestrator.notifications import insert_notification

    nid = insert_notification(svc.state["db"], "u1", kind="test")

    r = client.post(f"/notifications/{nid}/dismiss")
    assert r.status_code == 200
    assert r.json() == {"ok": True}

    r2 = client.get("/notifications")
    assert r2.status_code == 200
    assert r2.json()["notifications"] == []


def test_post_notification_rule(client):
    """POST a valid notification rule; response includes id + echoed fields."""
    r = client.post("/notification_rules", json={"kind": "period_pct", "threshold": 50})
    assert r.status_code == 200
    body = r.json()
    assert "id" in body
    assert body["kind"] == "period_pct"
    assert body["threshold"] == 50
    assert body["enabled"] is True


def test_patch_notification_rule(client):
    """POST a rule then PATCH threshold + enabled=False; both fields updated."""
    r = client.post("/notification_rules", json={"kind": "daily_amount", "threshold": 100})
    assert r.status_code == 200
    rid = r.json()["id"]

    r2 = client.patch(f"/notification_rules/{rid}", json={"threshold": 200, "enabled": False})
    assert r2.status_code == 200
    body = r2.json()
    assert body["threshold"] == 200
    assert body["enabled"] is False


def test_delete_notification_rule(client):
    """POST a rule then DELETE it; subsequent GET returns empty list."""
    r = client.post("/notification_rules", json={"kind": "daily_amount", "threshold": 100})
    assert r.status_code == 200
    rid = r.json()["id"]

    r2 = client.delete(f"/notification_rules/{rid}")
    assert r2.status_code == 200
    assert r2.json() == {"ok": True}

    r3 = client.get("/notification_rules")
    assert r3.status_code == 200
    assert all(rule["id"] != rid for rule in r3.json()["rules"])


def test_post_push_device_unifiedpush(client):
    """Register a unifiedpush device with endpoint_url; response echoes provider."""
    r = client.post("/push/devices", json={
        "provider": "unifiedpush",
        "endpoint_url": "https://distributor.example/upo/abc",
        "label": "Phone",
        "platform": "android",
    })
    assert r.status_code == 200
    body = r.json()
    assert body["provider"] == "unifiedpush"
    assert "id" in body


def test_post_push_device_desktop_local(client):
    """Register a desktop_local device (no endpoint_url required); endpoint_url is None."""
    r = client.post("/push/devices", json={"provider": "desktop_local", "label": "Linux laptop"})
    assert r.status_code == 200
    body = r.json()
    assert body["endpoint_url"] is None


def test_post_push_device_rejects_unknown_provider(client):
    """Unknown provider (fcm) is rejected with 400."""
    r = client.post("/push/devices", json={"provider": "fcm", "endpoint_url": "x"})
    assert r.status_code == 400


def test_delete_push_device(client):
    """POST a device then DELETE it; subsequent GET returns empty list."""
    r = client.post("/push/devices", json={"provider": "desktop_local", "label": "x"})
    assert r.status_code == 200
    did = r.json()["id"]

    r2 = client.delete(f"/push/devices/{did}")
    assert r2.status_code == 200
    assert r2.json() == {"ok": True}

    r3 = client.get("/push/devices")
    assert r3.status_code == 200
    assert all(d["id"] != did for d in r3.json()["devices"])
