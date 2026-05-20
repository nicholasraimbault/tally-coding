"""Sprint 46 A12: billing routes — credits balance, caps, checkout, auto-recharge."""
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

    return TestClient(svc.app, raise_server_exceptions=True)


def _headers():
    return {"Authorization": "Bearer test-token"}


def _mock_pro_beta_user():
    from tally_orchestrator.clerk_auth import User as ClerkUser
    return ClerkUser(id="u1", source="clerk", plan="pro_beta", email="u1@x.com")


def test_get_credits_returns_balance(client):
    """pro_beta user gets correct balance with plan metadata."""
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    db.get_or_create_quota("u1", plan_hint="pro_beta")

    svc.app.dependency_overrides[svc.require_user] = _mock_pro_beta_user
    try:
        r = client.get("/billing/credits", headers=_headers())
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["plan"] == "pro_beta"
        assert body["included_credits"] == 1000
        assert body["used_credits"] == 0
        assert body["available_credits"] == 1000
        assert body["prepaid_credit_balance"] == 0
    finally:
        svc.app.dependency_overrides.clear()


def test_get_caps_returns_defaults(client):
    """pro_beta user gets default per_task_cap; daily/weekly are null."""
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    db.get_or_create_quota("u1", plan_hint="pro_beta")

    svc.app.dependency_overrides[svc.require_user] = _mock_pro_beta_user
    try:
        r = client.get("/billing/caps", headers=_headers())
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["per_task_cap_credits"] == 100  # pro_beta default
        assert body["daily_spend_cap_credits"] is None
        assert body["weekly_spend_cap_credits"] is None
    finally:
        svc.app.dependency_overrides.clear()


def test_patch_caps_persists(client):
    """PATCH caps; subsequent GET reflects new values."""
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    db.get_or_create_quota("u1", plan_hint="pro_beta")

    svc.app.dependency_overrides[svc.require_user] = _mock_pro_beta_user
    try:
        r = client.patch(
            "/billing/caps",
            json={"per_task_cap_credits": 200, "daily_spend_cap_credits": 50},
            headers=_headers(),
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["per_task_cap_credits"] == 200
        assert body["daily_spend_cap_credits"] == 50

        # Verify persistence via a fresh GET.
        r2 = client.get("/billing/caps", headers=_headers())
        assert r2.status_code == 200, r2.text
        body2 = r2.json()
        assert body2["per_task_cap_credits"] == 200
        assert body2["daily_spend_cap_credits"] == 50
    finally:
        svc.app.dependency_overrides.clear()


def test_post_credits_checkout_under_minimum_returns_400(client):
    """credits=100 is below the 250-credit minimum; expect 400 with 'minimum' in detail."""
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    db.get_or_create_quota("u1", plan_hint="pro_beta")

    svc.app.dependency_overrides[svc.require_user] = _mock_pro_beta_user
    try:
        r = client.post(
            "/billing/credits/checkout",
            json={"credits": 100},
            headers=_headers(),
        )
        assert r.status_code == 400, r.text
        assert "minimum" in r.json()["detail"].lower()
    finally:
        svc.app.dependency_overrides.clear()


def test_post_credits_checkout_returns_stripe_url(client, monkeypatch):
    """credits=500 with mocked stripe_direct returns a Stripe checkout URL."""
    import tally_orchestrator.service as svc
    import tally_orchestrator.stripe_direct as sd
    db = svc.state["db"]
    db.get_or_create_quota("u1", plan_hint="pro_beta")

    fake_url = "https://checkout.stripe.com/c/pay/fake_session_123"
    monkeypatch.setattr(
        sd,
        "create_credits_checkout_session",
        lambda db, **kwargs: {"session_id": "cs_fake_123", "url": fake_url},
    )

    svc.app.dependency_overrides[svc.require_user] = _mock_pro_beta_user
    try:
        r = client.post(
            "/billing/credits/checkout",
            json={"credits": 500},
            headers=_headers(),
        )
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["url"].startswith("https://checkout.stripe.com/")
    finally:
        svc.app.dependency_overrides.clear()


def test_patch_auto_recharge_persists(client):
    """PATCH auto-recharge; subsequent GET /billing/credits reflects stored values."""
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    db.get_or_create_quota("u1", plan_hint="pro_beta")

    svc.app.dependency_overrides[svc.require_user] = _mock_pro_beta_user
    try:
        r = client.patch(
            "/billing/auto-recharge",
            json={"mode": 2, "block_credits": 1000, "monthly_cap_micro_usd": 50_000_000},
            headers=_headers(),
        )
        assert r.status_code == 200, r.text

        r2 = client.get("/billing/credits", headers=_headers())
        assert r2.status_code == 200, r2.text
        body = r2.json()
        assert body["auto_recharge_mode"] == 2
        assert body["auto_recharge_block_credits"] == 1000
        assert body["auto_recharge_monthly_cap_micro_usd"] == 50_000_000
    finally:
        svc.app.dependency_overrides.clear()
