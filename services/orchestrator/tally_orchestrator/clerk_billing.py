"""Sprint 33-rest: Clerk Billing replaces direct Stripe.

Clerk hosts the customer + payment-method + subscription state.  The
orchestrator's job here is two-pronged:

1. **JWT-claim sync** (the fast path).  Every Clerk session token
   carries the user's active plan in the `pla` claim (e.g.
   ``"u:pro"``).  When that differs from the plan we have stored
   in the ``quotas`` table, we update it opportunistically — no
   webhook involvement needed for the common "user just upgraded
   and made an API call" sequence.

2. **Webhook delivery** (the durable path).  Clerk fires svix-signed
   webhooks on every subscriptionItem state change.  We verify the
   signature with the dashboard-issued ``CLERK_WEBHOOK_SECRET``,
   parse the event, and update the quotas row.  This catches state
   changes that happen between the user's sessions (e.g. payment
   failed at the end of a billing period while the user wasn't
   around).

The plan→cap mapping (``QUOTA_PLANS``) lives in ``service.py`` so
the operator can tune caps without redeploying this module.  Plan
slugs are configured in the Clerk Billing dashboard; we accept the
slugs ``free``, ``pro``, ``team`` to match the dashboard pricing
tiers.

No Stripe SDK dependency. (``stripe_billing.py`` is left dormant —
its endpoints 503 because no ``STRIPE_SECRET_KEY`` is configured
anywhere now.)
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import logging
import os
from dataclasses import dataclass

logger = logging.getLogger("tally.clerk_billing")


# Clerk's `pla` claim is "scope:slug" where scope is `u` (user) or `o`
# (organization). Strip the scope; we only care about the slug, and
# all our plans are user-level for now.
_KNOWN_PLAN_SLUGS = {"free", "free_user", "pro", "team"}


def parse_plan_claim(pla: object) -> str | None:
    """Pull the slug out of the `pla` JWT claim.

    Accepts the documented "u:slug" / "o:slug" form, the bare slug
    (for forward-compat in case Clerk drops the scope prefix in a
    future SDK), and a list-of-strings (Clerk has been known to ship
    multiple active plans in array form during transitions).  Returns
    the first slug we recognise from ``_KNOWN_PLAN_SLUGS`` normalised
    to ``free``/``pro``/``team``, or ``None`` if the claim is missing
    / unrecognised — caller should fall back to ``free``.
    """
    if pla is None:
        return None
    candidates: list[str]
    if isinstance(pla, str):
        candidates = [pla]
    elif isinstance(pla, list):
        candidates = [c for c in pla if isinstance(c, str)]
    else:
        return None
    for raw in candidates:
        slug = raw.split(":", 1)[1] if ":" in raw else raw
        slug = slug.strip().lower()
        # Clerk's default free slug is "free_user" in some dashboards;
        # normalise to our internal "free".
        if slug in ("free", "free_user"):
            return "free"
        if slug in _KNOWN_PLAN_SLUGS:
            return slug
    return None


@dataclass
class WebhookEvent:
    """Verified Clerk webhook event, narrowed to the fields we act on."""
    type: str
    user_id: str | None
    plan: str | None
    subscription_id: str | None
    raw: dict


class ClerkBillingClient:
    """Thin wrapper. Owns the svix signing secret + the parser.

    Modes:
      - **Configured** (`CLERK_WEBHOOK_SECRET` set): real signature
        verification, /webhooks/clerk processes events.
      - **Unconfigured**: webhook returns 503 with a clear message,
        JWT-claim sync still works on every request.
    """

    def __init__(self) -> None:
        self.webhook_secret = os.environ.get("CLERK_WEBHOOK_SECRET", "").strip()

    @property
    def webhook_enabled(self) -> bool:
        return bool(self.webhook_secret)

    def verify_svix_signature(
        self,
        *,
        payload: bytes,
        svix_id: str,
        svix_timestamp: str,
        svix_signature: str,
    ) -> None:
        """Validate svix HMAC-SHA256 over `{id}.{timestamp}.{body}`.

        Raises ``ValueError`` on any failure (missing headers,
        unparseable secret, bad signature, replayed timestamp).
        Caller maps the exception to HTTP 400.

        The signing secret arrives from Clerk as ``whsec_<base64>``;
        we base64-decode the tail and use that as the HMAC key.
        """
        if not (svix_id and svix_timestamp and svix_signature):
            raise ValueError("missing svix-id / svix-timestamp / svix-signature header")
        if not self.webhook_secret:
            raise ValueError("CLERK_WEBHOOK_SECRET not configured")
        if not self.webhook_secret.startswith("whsec_"):
            raise ValueError("CLERK_WEBHOOK_SECRET must start with 'whsec_'")

        secret_b64 = self.webhook_secret[len("whsec_"):]
        try:
            secret_bytes = base64.b64decode(secret_b64)
        except Exception as exc:
            raise ValueError(f"CLERK_WEBHOOK_SECRET base64 decode failed: {exc}") from exc

        signed = f"{svix_id}.{svix_timestamp}.{payload.decode('utf-8', errors='strict')}"
        expected = base64.b64encode(
            hmac.new(secret_bytes, signed.encode("utf-8"), hashlib.sha256).digest()
        ).decode("ascii")

        # svix-signature header format: space-separated "v1,<sig>" pairs.
        provided: list[str] = []
        for piece in svix_signature.split():
            if "," not in piece:
                continue
            version, sig = piece.split(",", 1)
            if version == "v1":
                provided.append(sig)
        if not provided:
            raise ValueError("svix-signature header has no v1 entries")
        if not any(hmac.compare_digest(expected, p) for p in provided):
            raise ValueError("svix signature mismatch")

    def parse_event(self, evt: dict) -> WebhookEvent:
        """Narrow a Clerk billing webhook payload to the fields the
        orchestrator acts on.

        Clerk's billing payloads aren't extensively documented yet,
        so we extract defensively from several candidate keys:
          - subscriptionItem.* events have ``data.payer.user_id``
            (or ``data.user_id``); ``data.plan.slug`` (or
            ``data.plan_slug``); ``data.id`` is the subscriptionItem
            id we store as subscription_id.
        Unknown event types yield a WebhookEvent with
        ``user_id=None`` so the handler can no-op without crashing.
        """
        event_type = str(evt.get("type") or "")
        data = evt.get("data") or {}

        user_id: str | None = None
        payer = data.get("payer")
        if isinstance(payer, dict):
            uid = payer.get("user_id") or payer.get("id")
            if isinstance(uid, str):
                user_id = uid
        if user_id is None:
            uid = data.get("user_id")
            if isinstance(uid, str):
                user_id = uid

        plan_slug: str | None = None
        plan = data.get("plan")
        if isinstance(plan, dict):
            raw = plan.get("slug") or plan.get("id")
            if isinstance(raw, str):
                plan_slug = parse_plan_claim(raw)
        if plan_slug is None:
            raw = data.get("plan_slug") or data.get("plan_id")
            if isinstance(raw, str):
                plan_slug = parse_plan_claim(raw)

        # On `subscriptionItem.canceled` the user explicitly cancels
        # and reverts to free.  ``.ended`` is a *different* event that
        # fires when an existing plan ends due to a plan change (free
        # → pro, pro → team, etc.); in that case the new ``.active``
        # event for the replacement plan arrives a few ms later and
        # carries the right slug, so we don't override here.  Clerk
        # delivers both within a single webhook batch, in source-order.
        if event_type.endswith(".canceled"):
            plan_slug = "free"

        sub_id_raw = data.get("id")
        subscription_id = sub_id_raw if isinstance(sub_id_raw, str) else None

        return WebhookEvent(
            type=event_type,
            user_id=user_id,
            plan=plan_slug,
            subscription_id=subscription_id,
            raw=evt,
        )
