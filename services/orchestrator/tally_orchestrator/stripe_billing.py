"""Sprint 33: Stripe customer + subscription + webhook plumbing.

Two modes:
  - **Configured** (`STRIPE_SECRET_KEY` set): real Stripe customers,
    real hosted checkout sessions, webhook validates signatures with
    `STRIPE_WEBHOOK_SECRET`.
  - **Unconfigured**: `BillingClient.enabled` is False; the `/billing/*`
    endpoints 503 with a clear "Stripe not configured" message so the
    free-tier path still works without any Stripe setup.

Plan→price mapping comes from env vars (`STRIPE_PRICE_PRO`,
`STRIPE_PRICE_TEAM`) so the operator can swap test/live prices without
touching code.
"""
from __future__ import annotations

import logging
import os
from dataclasses import dataclass

logger = logging.getLogger("tally.billing")


@dataclass
class CheckoutSession:
    url: str
    session_id: str


class BillingClient:
    """Thin wrapper around the Stripe Python SDK. Lazy-imports `stripe`
    so the orchestrator still boots when the package isn't installed
    (development tier where billing isn't configured).
    """

    def __init__(self) -> None:
        self.secret_key = os.environ.get("STRIPE_SECRET_KEY", "").strip()
        self.webhook_secret = os.environ.get("STRIPE_WEBHOOK_SECRET", "").strip()
        self.price_pro = os.environ.get("STRIPE_PRICE_PRO", "").strip()
        self.price_team = os.environ.get("STRIPE_PRICE_TEAM", "").strip()
        self.success_url = os.environ.get(
            "STRIPE_SUCCESS_URL",
            "https://tally.pronoic.dev/billing/success?session_id={CHECKOUT_SESSION_ID}",
        )
        self.cancel_url = os.environ.get(
            "STRIPE_CANCEL_URL", "https://tally.pronoic.dev/billing/cancel",
        )
        self._stripe = None  # lazy

    @property
    def enabled(self) -> bool:
        return bool(self.secret_key)

    def _client(self):
        if self._stripe is None:
            import stripe  # type: ignore
            stripe.api_key = self.secret_key
            self._stripe = stripe
        return self._stripe

    def price_for_plan(self, plan: str) -> str | None:
        return {"pro": self.price_pro, "team": self.price_team}.get(plan)

    def create_or_get_customer(self, *, user_id: str, email: str | None) -> str:
        """Create a Stripe Customer keyed to the Clerk user_id (stored
        in metadata.tally_user_id). Idempotent within a single call:
        searches first, creates if missing."""
        stripe = self._client()
        # Stripe's Customer.list supports query='metadata["tally_user_id"]:...'
        try:
            existing = stripe.Customer.search(
                query=f"metadata['tally_user_id']:'{user_id}'", limit=1,
            )
            if existing.data:
                return existing.data[0].id
        except Exception as exc:
            logger.warning("Stripe Customer.search failed; falling through to create: %s", exc)
        cust = stripe.Customer.create(
            email=email,
            metadata={"tally_user_id": user_id},
        )
        return cust.id

    def create_checkout_session(
        self,
        *,
        user_id: str,
        email: str | None,
        plan: str,
    ) -> CheckoutSession:
        stripe = self._client()
        price = self.price_for_plan(plan)
        if not price:
            raise ValueError(f"no Stripe price configured for plan={plan}")
        customer_id = self.create_or_get_customer(user_id=user_id, email=email)
        session = stripe.checkout.Session.create(
            mode="subscription",
            customer=customer_id,
            line_items=[{"price": price, "quantity": 1}],
            success_url=self.success_url,
            cancel_url=self.cancel_url,
            metadata={"tally_user_id": user_id, "plan": plan},
            subscription_data={"metadata": {"tally_user_id": user_id, "plan": plan}},
        )
        return CheckoutSession(url=session.url, session_id=session.id)

    def validate_webhook(self, *, payload: bytes, signature: str) -> dict:
        """Raises if the signature is invalid. Returns the parsed event."""
        if not self.webhook_secret:
            raise ValueError("STRIPE_WEBHOOK_SECRET not configured")
        stripe = self._client()
        return stripe.Webhook.construct_event(
            payload=payload, sig_header=signature, secret=self.webhook_secret,
        )
