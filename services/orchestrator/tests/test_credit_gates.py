"""Sprint 46: POST /tasks pre-submit credit gates."""
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

    return TestClient(svc.app, raise_server_exceptions=True)


def _headers():
    return {"Authorization": "Bearer test-token"}


def test_402_when_credits_exhausted(client):
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    # User starts as pro_beta with 1000 credits.
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    # Use up all 1000.
    db.record_cost_event(
        user_id="u1", kind="architect", model="meta-llama/llama-3.3-70b-instruct",
        prompt_tokens=0, completion_tokens=0, total_tokens=0,
        cost_micro_usd=10_000_000,  # 1000 credits
    )
    # Override require_user to return a test user without auth.
    from tally_orchestrator.clerk_auth import User as ClerkUser
    def _mock_user():
        return ClerkUser(id="u1", source="clerk", plan="pro_beta", email="u1@x.com")
    svc.app.dependency_overrides[svc.require_user] = _mock_user
    try:
        r = client.post("/tasks", json={"description": "hi"}, headers=_headers())
        assert r.status_code == 402
        body = r.json()["detail"]
        assert body["error"] == "no_credits_remaining"
        assert body["available_credits"] == 0
    finally:
        svc.app.dependency_overrides.clear()


def test_402_when_daily_cap_reached(client):
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    db.set_daily_cap("u1", 50)
    # Use 60 credits today.
    db.record_cost_event(
        user_id="u1", kind="architect", model="meta-llama/llama-3.3-70b-instruct",
        prompt_tokens=0, completion_tokens=0, total_tokens=0,
        cost_micro_usd=600_000,  # 60 credits
    )
    from tally_orchestrator.clerk_auth import User as ClerkUser
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="u1", source="clerk", plan="pro_beta", email="u1@x.com",
    )
    try:
        r = client.post("/tasks", json={"description": "hi"}, headers=_headers())
        assert r.status_code == 402
        assert r.json()["detail"]["error"] == "daily_cap_reached"
    finally:
        svc.app.dependency_overrides.clear()


def test_passes_when_credits_available(client, monkeypatch):
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    # Ensure redpill_key is empty so the architect branch is skipped.
    monkeypatch.setattr(svc.state["orchestrator"], "redpill_key", None)
    from tally_orchestrator.clerk_auth import User as ClerkUser
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="u1", source="clerk", plan="pro_beta", email="u1@x.com",
    )
    try:
        r = client.post("/tasks", json={"description": "hi"}, headers=_headers())
        assert r.status_code == 200
        assert "id" in r.json()
    finally:
        svc.app.dependency_overrides.clear()
