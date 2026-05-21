"""Sprint 49: HMAC-verified webhook handler for persistent-agent event triggers."""
import hashlib
import hmac
import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch, tmp_db_path):
    monkeypatch.setenv("ORCH_DB_PATH", tmp_db_path)
    monkeypatch.setenv("TALLY_API_TOKEN", "test-token")
    monkeypatch.setenv("TALLY_REDPILL_KEY", "")
    monkeypatch.setenv("TALLY_TEST_MODE", "1")
    import importlib, tally_orchestrator.service as svc
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


def _make_agent_with_trigger(client) -> tuple[int, str, str]:
    """Returns (agent_id, trigger_id, secret)."""
    r = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "webhook-test", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
        "event_triggers": [{"kind": "http", "name": "default"}],
    })
    body = r.json()
    agent_id = body["id"]
    trig = body["event_triggers"][0]
    return agent_id, trig["id"], trig["secret"]


def test_valid_hmac_fires_agent(client):
    agent_id, trig_id, secret = _make_agent_with_trigger(client)
    payload = b'{"hello":"world"}'
    sig = "sha256=" + hmac.new(secret.encode(), payload, hashlib.sha256).hexdigest()
    r = client.post(
        f"/webhooks/agents/{trig_id}",
        content=payload,
        headers={"X-Tally-Signature": sig, "content-type": "application/json"},
    )
    assert r.status_code == 200
    assert r.json()["agent_id"] == agent_id


def test_invalid_hmac_returns_401(client):
    _agent_id, trig_id, _secret = _make_agent_with_trigger(client)
    payload = b'{"hello":"world"}'
    bad_sig = "sha256=" + "0" * 64
    r = client.post(
        f"/webhooks/agents/{trig_id}",
        content=payload,
        headers={"X-Tally-Signature": bad_sig, "content-type": "application/json"},
    )
    assert r.status_code == 401


def test_unknown_trigger_returns_404(client):
    r = client.post(
        "/webhooks/agents/nonexistent",
        content=b'{}',
        headers={"X-Tally-Signature": "sha256=" + "0" * 64},
    )
    assert r.status_code == 404
