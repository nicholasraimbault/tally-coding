# services/orchestrator/tally_orchestrator/stripe_direct.py
"""Sprint 46: direct Stripe integration for one-time credit purchases
and off-session auto-recharge.

`STRIPE_SECRET_KEY` is the operator-supplied restricted Stripe API key
with scopes: charges:write, payment_intents:write,
checkout_sessions:write, customers:read, payment_methods:read.
Webhooks land at `/webhooks/stripe` (handler in service.py).

Idempotency: every off-session PaymentIntent.create uses
`recharge_{user_id}_{int(period_start)}_{already_spent}` so retries
in tight loops collapse into a single charge.

Mode-3 (unlimited auto-recharge) + Stripe outage: the API exception
propagates; the caller in POST /tasks maps it to 503.  No credit is
ever granted speculatively.  This is the "never spend more than we
make" invariant.
"""
from __future__ import annotations

import asyncio
import logging
import os
import time
from typing import TYPE_CHECKING

from .credits import OVERAGE_CREDIT_PRICE_MICRO_USD, MIN_PURCHASE_CREDITS

if TYPE_CHECKING:
    from .service import Db

logger = logging.getLogger("tally.stripe_direct")


class StripeNotConfiguredError(RuntimeError):
    """STRIPE_SECRET_KEY missing — Stripe paths cannot run."""


def _stripe():
    """Return the configured stripe module or raise.

    Kept for backward compatibility with `stripe.Webhook.construct_event`,
    which is still a static call in stripe-python 15.x.  All Checkout
    Session and PaymentIntent calls use `_stripe_client()` instead —
    the static-class API was dropped in stripe-python 15.0.
    """
    key = os.environ.get("STRIPE_SECRET_KEY", "").strip()
    if not key:
        raise StripeNotConfiguredError("STRIPE_SECRET_KEY not configured")
    import stripe
    stripe.api_key = key
    return stripe


def _stripe_client():
    """Return a configured StripeClient (stripe-python 15.x API)."""
    key = os.environ.get("STRIPE_SECRET_KEY", "").strip()
    if not key:
        raise StripeNotConfiguredError("STRIPE_SECRET_KEY not configured")
    import stripe
    return stripe.StripeClient(key)


def recharge_idempotency_key(*, user_id: str, period_start: float, already_spent: int) -> str:
    """Stable key for off-session PaymentIntent retries."""
    return f"recharge_{user_id}_{int(period_start)}_{already_spent}"


def create_credits_checkout_session(
    db: "Db",
    *,
    user_id: str,
    credits: int,
    success_url: str,
    cancel_url: str,
) -> dict:
    """One-time credit purchase via hosted Checkout Session.

    Returns {"session_id": str, "url": str}.  Caller hands the URL
    to the Flutter client; Stripe redirects to `success_url` on
    completion and the webhook handler credits the prepaid balance.
    """
    if credits < MIN_PURCHASE_CREDITS:
        raise ValueError(
            f"minimum purchase is {MIN_PURCHASE_CREDITS} credits "
            f"(${MIN_PURCHASE_CREDITS * OVERAGE_CREDIT_PRICE_MICRO_USD // 10000 / 100:.2f})"
        )
    client = _stripe_client()
    quota = db.get_or_create_quota(user_id)
    amount_cents = credits * OVERAGE_CREDIT_PRICE_MICRO_USD // 10_000  # micro_usd → cents
    params = {
        "mode": "payment",
        "success_url": success_url,
        "cancel_url": cancel_url,
        "line_items": [{
            "price_data": {
                "currency": "usd",
                "product_data": {"name": f"{credits} Tally credits"},
                "unit_amount": amount_cents,
            },
            "quantity": 1,
        }],
        "metadata": {
            "user_id": user_id,
            "credits": str(credits),
            "purchase_kind": "one_time",
        },
    }
    customer_id = quota.get("stripe_customer_id")
    if customer_id:
        params["customer"] = customer_id  # omit → Stripe creates a new Customer
    session = client.checkout.sessions.create(params)
    db._conn.execute(
        "INSERT INTO overage_purchases "
        "(user_id, ts, credits_purchased, cost_charged_micro_usd, kind, status, stripe_payment_intent_id) "
        "VALUES (?, ?, ?, ?, 'one_time', 'pending', ?)",
        (
            user_id, time.time(), credits,
            credits * OVERAGE_CREDIT_PRICE_MICRO_USD,
            getattr(session, "payment_intent", None) if isinstance(getattr(session, "payment_intent", None), (str, type(None))) else None,
        ),
    )
    return {"session_id": session.id, "url": session.url}


def create_setup_session(
    db: "Db",
    *,
    user_id: str,
    success_url: str,
    cancel_url: str,
) -> dict:
    """Setup-mode Checkout for saving a card without charging.

    Used by Modes 2 + 3 to capture a payment method that we later
    charge off-session.
    """
    client = _stripe_client()
    quota = db.get_or_create_quota(user_id)
    params = {
        "mode": "setup",
        # Stripe requires `currency` for setup-mode Checkout — it's the
        # currency of any future off-session charges against the saved
        # card.  Tally bills USD.
        "currency": "usd",
        "success_url": success_url,
        "cancel_url": cancel_url,
        "metadata": {
            "user_id": user_id,
            "purchase_kind": "auto_recharge_setup",
        },
    }
    customer_id = quota.get("stripe_customer_id")
    if customer_id:
        params["customer"] = customer_id
    session = client.checkout.sessions.create(params)
    return {"session_id": session.id, "url": session.url}


async def trigger_auto_recharge_unlimited(db: "Db", user_id: str) -> int:
    """Mode 3: unlimited auto-recharge.  Buys one block.  Raises on
    any Stripe failure — caller must NOT credit speculatively."""
    return await _trigger_off_session_charge(db, user_id, capped=False)


async def trigger_auto_recharge_capped(db: "Db", user_id: str) -> bool:
    """Mode 2: capped auto-recharge.  Returns True if a charge fired;
    False if monthly cap would be exceeded.  Raises on Stripe failure."""
    quota = db.get_or_create_quota(user_id)
    cap = quota.get("auto_recharge_monthly_cap_micro_usd")
    spent = int(quota.get("auto_recharge_spent_this_month_micro_usd") or 0)
    block_credits = int(quota.get("auto_recharge_block_credits") or 500)
    block_cost = block_credits * OVERAGE_CREDIT_PRICE_MICRO_USD
    if cap is not None and (spent + block_cost) > int(cap):
        logger.info(
            "auto_recharge_capped: user=%s would exceed monthly cap (%d + %d > %d)",
            user_id, spent, block_cost, int(cap),
        )
        return False
    await _trigger_off_session_charge(db, user_id, capped=True)
    return True


async def _trigger_off_session_charge(db: "Db", user_id: str, *, capped: bool) -> int:
    """Common path for both auto-recharge modes."""
    client = _stripe_client()
    quota = db.get_or_create_quota(user_id)
    pm = quota.get("stripe_payment_method_id")
    customer = quota.get("stripe_customer_id")
    if not pm or not customer:
        raise RuntimeError(f"user {user_id} has no saved card for auto-recharge")
    block_credits = int(quota.get("auto_recharge_block_credits") or 500)
    amount_micro = block_credits * OVERAGE_CREDIT_PRICE_MICRO_USD
    amount_cents = amount_micro // 10_000
    already_spent = int(quota.get("auto_recharge_spent_this_month_micro_usd") or 0)
    key = recharge_idempotency_key(
        user_id=user_id, period_start=quota["period_start"], already_spent=already_spent,
    )
    kind = "auto_recharge" + ("_capped" if capped else "_unlimited")

    # Record the pending purchase BEFORE the Stripe call so a crash
    # between charge and INSERT can't strand a real charge with no
    # local row.  Webhook `payment_intent.succeeded` finalizes status
    # to 'succeeded' and credits the balance.  The row's `stripe_payment_intent_id`
    # column is filled in after the Stripe call succeeds; the idempotency
    # key + (user_id, ts) is enough to dedupe webhook retries until
    # then.
    cursor = db._conn.execute(
        "INSERT INTO overage_purchases "
        "(user_id, ts, credits_purchased, cost_charged_micro_usd, kind, status) "
        "VALUES (?, ?, ?, ?, ?, 'pending')",
        (user_id, time.time(), block_credits, amount_micro, kind),
    )
    pending_row_id = cursor.lastrowid

    def _create_pi():
        return client.payment_intents.create(
            {
                "amount": amount_cents,
                "currency": "usd",
                "customer": customer,
                "payment_method": pm,
                "off_session": True,
                "confirm": True,
                "metadata": {
                    "user_id": user_id,
                    "credits": str(block_credits),
                    "purchase_kind": kind,
                },
            },
            options={"idempotency_key": key},
        )

    try:
        pi = await asyncio.to_thread(_create_pi)
    except Exception as exc:
        # Mark the pending row failed so /billing/credits can show
        # the failure reason without depending on the webhook.
        db._conn.execute(
            "UPDATE overage_purchases SET status='failed', failure_reason=? WHERE id=?",
            (str(exc)[:500], pending_row_id),
        )
        raise
    db._conn.execute(
        "UPDATE overage_purchases SET stripe_payment_intent_id=? WHERE id=?",
        (pi.id, pending_row_id),
    )
    db._conn.execute(
        "UPDATE quotas SET auto_recharge_spent_this_month_micro_usd = "
        "auto_recharge_spent_this_month_micro_usd + ?, updated_at=? WHERE user_id=?",
        (amount_micro, time.time(), user_id),
    )
    logger.info(
        "auto_recharge fired: user=%s pi=%s credits=%d capped=%s",
        user_id, pi.id, block_credits, capped,
    )
    return block_credits
