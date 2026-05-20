"""Sprint 46: Stripe webhook handler."""
import json
import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch, tmp_db_path):
    # Set env vars before the module-level config picks them up.
    monkeypatch.setenv("ORCH_DB_PATH", tmp_db_path)
    monkeypatch.setenv("TALLY_API_TOKEN", "test-token")
    monkeypatch.setenv("REDPILL_API_KEY", "")  # disables architect call
    monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_test_xxx")
    monkeypatch.setenv("STRIPE_WEBHOOK_SECRET", "whsec_test")

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


def _fake_event(evt_type: str, data: dict) -> dict:
    return {"id": "evt_test_1", "type": evt_type, "data": {"object": data}}


def test_checkout_completed_credits_user(client, monkeypatch):
    """checkout.session.completed → prepaid_credit_balance += credits."""
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    db._conn.execute(
        "INSERT INTO overage_purchases "
        "(user_id, ts, credits_purchased, cost_charged_micro_usd, kind, "
        "stripe_payment_intent_id, status) "
        "VALUES ('u1', 0, 500, 10000000, 'one_time', 'pi_test_1', 'pending')",
    )
    event = _fake_event("checkout.session.completed", {
        "id": "cs_test_1",
        "metadata": {"user_id": "u1", "credits": "500", "purchase_kind": "one_time"},
        "payment_intent": "pi_test_1",
    })
    monkeypatch.setattr(
        "tally_orchestrator.service._verify_stripe_signature",
        lambda payload, sig: event,
    )
    r = client.post(
        "/webhooks/stripe",
        content=json.dumps(event).encode(),
        headers={"stripe-signature": "t=0,v1=fake"},
    )
    assert r.status_code == 200
    assert db.get_prepaid_balance("u1") == 500


def test_setup_intent_succeeded_saves_payment_method(client, monkeypatch):
    """setup_intent.succeeded → quotas.stripe_payment_method_id + stripe_customer_id set."""
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    event = _fake_event("setup_intent.succeeded", {
        "id": "seti_test_1",
        "payment_method": "pm_test_1",
        "customer": "cus_test_1",
        "metadata": {"user_id": "u1"},
    })
    monkeypatch.setattr(
        "tally_orchestrator.service._verify_stripe_signature",
        lambda payload, sig: event,
    )
    r = client.post(
        "/webhooks/stripe",
        content=json.dumps(event).encode(),
        headers={"stripe-signature": "t=0,v1=fake"},
    )
    assert r.status_code == 200
    row = db._conn.execute(
        "SELECT stripe_payment_method_id, stripe_customer_id FROM quotas WHERE user_id='u1'",
    ).fetchone()
    assert row[0] == "pm_test_1"
    assert row[1] == "cus_test_1"


def test_payment_intent_failed_disables_auto_recharge(client, monkeypatch):
    """payment_intent.payment_failed → auto_recharge_mode=0, overage_enabled=0."""
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    db._conn.execute(
        "UPDATE quotas SET auto_recharge_mode=2, overage_enabled=1 WHERE user_id='u1'",
    )
    event = _fake_event("payment_intent.payment_failed", {
        "id": "pi_test_2",
        "metadata": {"user_id": "u1", "credits": "500"},
        "last_payment_error": {"message": "card_declined"},
    })
    monkeypatch.setattr(
        "tally_orchestrator.service._verify_stripe_signature",
        lambda payload, sig: event,
    )
    r = client.post(
        "/webhooks/stripe",
        content=json.dumps(event).encode(),
        headers={"stripe-signature": "t=0,v1=fake"},
    )
    assert r.status_code == 200
    row = db._conn.execute(
        "SELECT auto_recharge_mode, overage_enabled FROM quotas WHERE user_id='u1'",
    ).fetchone()
    assert row[0] == 0
    assert row[1] == 0


def test_duplicate_payment_intent_webhook_is_idempotent(client, monkeypatch):
    """Webhook retries must not double-credit."""
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    db._conn.execute(
        "INSERT INTO overage_purchases "
        "(user_id, ts, credits_purchased, cost_charged_micro_usd, kind, "
        "stripe_payment_intent_id, status) "
        "VALUES ('u1', 0, 500, 10000000, 'auto_recharge_unlimited', 'pi_test_3', 'pending')",
    )
    event = _fake_event("payment_intent.succeeded", {
        "id": "pi_test_3",
        "metadata": {"user_id": "u1", "credits": "500"},
    })
    monkeypatch.setattr(
        "tally_orchestrator.service._verify_stripe_signature",
        lambda payload, sig: event,
    )
    r1 = client.post(
        "/webhooks/stripe",
        content=json.dumps(event).encode(),
        headers={"stripe-signature": "t=0,v1=fake"},
    )
    r2 = client.post(
        "/webhooks/stripe",
        content=json.dumps(event).encode(),
        headers={"stripe-signature": "t=0,v1=fake"},
    )
    assert r1.status_code == 200
    assert r2.status_code == 200
    assert db.get_prepaid_balance("u1") == 500  # NOT 1000
