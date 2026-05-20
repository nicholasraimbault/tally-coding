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

    # stripe-python 15.x: instance-based client (StripeClient).
    fake_client = MagicMock()
    fake_client.checkout.sessions.create = MagicMock(
        return_value=MagicMock(id="cs_test_123", url="https://checkout.stripe.com/cs_test_123"),
    )
    fake = MagicMock()
    fake.StripeClient = MagicMock(return_value=fake_client)
    with patch.dict("sys.modules", {"stripe": fake}):
        import importlib, tally_orchestrator.stripe_direct as sd
        importlib.reload(sd)
        out = sd.create_credits_checkout_session(
            db, user_id="u1", credits=500, success_url="x://success", cancel_url="x://cancel",
        )
        assert out["url"].startswith("https://checkout.stripe.com/")
        assert out["session_id"] == "cs_test_123"
    fake_client.checkout.sessions.create.assert_called_once()


def test_idempotency_key_format():
    from tally_orchestrator.stripe_direct import recharge_idempotency_key
    key = recharge_idempotency_key(user_id="u1", period_start=1_700_000_000.0, already_spent=500)
    assert key == "recharge_u1_1700000000_500"


def test_capped_recharge_returns_false_when_monthly_cap_exceeded(monkeypatch, db):
    """Mode 2: if (already_spent + block_cost) > monthly_cap, return False without Stripe call."""
    monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_test_xxx")
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    # Already spent $20 of $25 cap; one block at 500 credits = $10 → over cap
    db._conn.execute(
        "UPDATE quotas SET auto_recharge_mode=2, "
        "auto_recharge_monthly_cap_micro_usd=25_000_000, "
        "auto_recharge_spent_this_month_micro_usd=20_000_000, "
        "auto_recharge_block_credits=500 WHERE user_id=?",
        ("u1",),
    )

    fake = MagicMock()
    fake.PaymentIntent.create = MagicMock()
    with patch.dict("sys.modules", {"stripe": fake}):
        import importlib, tally_orchestrator.stripe_direct as sd
        importlib.reload(sd)
        import asyncio
        result = asyncio.run(sd.trigger_auto_recharge_capped(db, "u1"))
        assert result is False
    fake.PaymentIntent.create.assert_not_called()


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
