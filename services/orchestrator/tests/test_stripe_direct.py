"""Sprint 46: stripe_direct.py — Checkout Session + off-session PaymentIntent."""
from unittest.mock import MagicMock, patch
import pytest


def test_module_imports_when_key_unset(monkeypatch):
    """stripe_direct should be importable even if STRIPE_SECRET_KEY is missing;
    individual functions raise StripeNotConfiguredError on use."""
    monkeypatch.delenv("STRIPE_SECRET_KEY", raising=False)
    from tally_orchestrator import stripe_direct
    assert stripe_direct is not None


def test_create_checkout_session_calls_stripe(monkeypatch, db):
    monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_test_xxx")
    db.get_or_create_quota("u1", plan_hint="pro_beta")

    fake = MagicMock()
    fake.Checkout.Session.create = MagicMock(
        return_value=MagicMock(id="cs_test_123", url="https://checkout.stripe.com/cs_test_123"),
    )
    with patch.dict("sys.modules", {"stripe": fake}):
        import importlib, tally_orchestrator.stripe_direct as sd
        importlib.reload(sd)
        out = sd.create_credits_checkout_session(
            db, user_id="u1", credits=500, success_url="x://success", cancel_url="x://cancel",
        )
        assert out["url"].startswith("https://checkout.stripe.com/")
        assert out["session_id"] == "cs_test_123"
    fake.Checkout.Session.create.assert_called_once()


def test_idempotency_key_format():
    from tally_orchestrator.stripe_direct import recharge_idempotency_key
    key = recharge_idempotency_key(user_id="u1", period_start=1_700_000_000.0, already_spent=500)
    assert key == "recharge_u1_1700000000_500"


def test_unlimited_recharge_raises_when_stripe_down(monkeypatch, db):
    monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_test_xxx")
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    db._conn.execute(
        "UPDATE quotas SET auto_recharge_mode=3, stripe_payment_method_id=?, "
        "stripe_customer_id=? WHERE user_id=?",
        ("pm_test", "cus_test", "u1"),
    )

    fake = MagicMock()
    fake.error = MagicMock()
    fake.error.APIConnectionError = Exception
    fake.PaymentIntent.create = MagicMock(side_effect=Exception("connection failed"))
    with patch.dict("sys.modules", {"stripe": fake}):
        import importlib, tally_orchestrator.stripe_direct as sd
        importlib.reload(sd)
        import asyncio
        with pytest.raises(Exception):
            asyncio.run(sd.trigger_auto_recharge_unlimited(db, "u1"))
