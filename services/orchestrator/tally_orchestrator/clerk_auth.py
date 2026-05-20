"""Sprint 32: Clerk JWT validator.

Validates Bearer tokens issued by Clerk against the publishable key's
JWKS endpoint. Caches the JWKS for `_JWKS_TTL_S` to avoid hitting Clerk
on every request. Returns the extracted user_id (Clerk's `sub` claim)
so the orchestrator can scope per-user data.

Two auth sources coexist:
  - "admin": the legacy TALLY_API_TOKEN (cron jobs, scripts) — keep
    working for the operator surface (/admin/*).
  - "clerk": real users signed into the Flutter app.

This module owns the "clerk" path. The route's `require_user` dispatches
based on whether the bearer is a JWT (starts with `eyJ`) or a static
admin token.
"""
from __future__ import annotations

import base64
import logging
import time
from dataclasses import dataclass

import jwt
from jwt import PyJWKClient

logger = logging.getLogger("tally.clerk")


@dataclass
class User:
    """Resolved user from the request's Authorization header.

    Sources:
      - `clerk`: validated Clerk JWT; `id` is the Clerk user_id (sub).
      - `admin`: legacy TALLY_API_TOKEN; `id` is 'admin'. Admin can
        read/write any user's data + reach /admin/* endpoints.

    Sprint 33-rest: the `plan` field carries the Clerk Billing plan
    slug extracted from the JWT's `pla` claim ("free" | "pro" |
    "team"), or None when the claim is absent (legacy admin token).
    The orchestrator uses this for opportunistic quota-row syncing.
    """
    id: str
    source: str          # "clerk" | "admin"
    email: str | None = None
    github: str | None = None
    plan: str | None = None


_JWKS_TTL_S = 600  # 10 min: Clerk's JWKS is stable in practice.


class ClerkValidator:
    """Thread-safe-enough JWT validator. One instance per orchestrator;
    caches the JWKS client to amortize the HTTPS fetch + RSA parsing.

    Construct with the publishable key (`pk_test_…` or `pk_live_…`);
    the frontend API URL is base64-encoded inside it, no additional
    config needed.
    """

    def __init__(self, publishable_key: str) -> None:
        self.publishable_key = publishable_key
        self.frontend_api = _decode_publishable_key(publishable_key)
        self.issuer = f"https://{self.frontend_api}"
        self.jwks_url = f"{self.issuer}/.well-known/jwks.json"
        self._jwks_client: PyJWKClient | None = None
        self._jwks_fetched_at: float = 0.0
        logger.info("Clerk validator ready: issuer=%s", self.issuer)

    def _jwks(self) -> PyJWKClient:
        now = time.time()
        if self._jwks_client is None or (now - self._jwks_fetched_at) > _JWKS_TTL_S:
            # PyJWKClient fetches lazily on first get_signing_key_from_jwt;
            # but constructing it eagerly hits the network here.
            self._jwks_client = PyJWKClient(self.jwks_url, cache_jwk_set=True, lifespan=_JWKS_TTL_S)
            self._jwks_fetched_at = now
        return self._jwks_client

    def validate(self, token: str) -> User:
        """Validate a Clerk JWT. Raises jwt.PyJWTError subclasses on
        any failure (signature, expiry, issuer, missing-sub)."""
        signing_key = self._jwks().get_signing_key_from_jwt(token).key
        claims = jwt.decode(
            token,
            signing_key,
            algorithms=["RS256"],
            issuer=self.issuer,
            # Clerk session tokens don't always include `aud` for the
            # default JWT template; skip audience validation to avoid
            # forcing operators to configure a custom JWT template.
            options={"verify_aud": False},
        )
        sub = claims.get("sub")
        if not isinstance(sub, str) or not sub:
            raise jwt.InvalidTokenError("missing sub claim")
        # Common Clerk claims (depend on JWT template; both are
        # optional). Email comes from Clerk session tokens; github
        # from Clerk's GitHub-OAuth-link metadata.
        email = claims.get("email")
        github = (
            claims.get("github")
            or (claims.get("external_accounts") or {}).get("github")
            or None
        )
        # Sprint 33-rest: Clerk Billing puts the active plan into
        # `pla` ("u:pro" / "o:team") on v2 session tokens.  We let
        # `clerk_billing.parse_plan_claim` normalise the slug so
        # this module doesn't grow plan-vocabulary knowledge.
        from .clerk_billing import parse_plan_claim
        plan = parse_plan_claim(claims.get("pla"))
        return User(
            id=sub,
            source="clerk",
            email=email if isinstance(email, str) else None,
            github=github if isinstance(github, str) else None,
            plan=plan,
        )


def _decode_publishable_key(pk: str) -> str:
    """Pull the Clerk frontend API host out of the publishable key.

    Clerk keys look like ``pk_test_<base64>`` where the base64 decodes
    to ``<frontend-api>$`` — e.g.
    ``pk_test_ZWFnZXItc2hyaW1wLTM2LmNsZXJrLmFjY291bnRzLmRldiQ`` →
    ``eager-shrimp-36.clerk.accounts.dev``.
    """
    for prefix in ("pk_test_", "pk_live_"):
        if pk.startswith(prefix):
            tail = pk[len(prefix):]
            try:
                decoded = base64.b64decode(tail + "=" * (-len(tail) % 4)).decode("utf-8")
            except Exception as exc:
                raise ValueError(f"unparseable publishable key: {exc}") from exc
            return decoded.rstrip("$")
    raise ValueError(f"unrecognised publishable-key prefix: {pk[:8]}…")


def looks_like_jwt(token: str) -> bool:
    """Cheap heuristic: real JWTs start with `eyJ` (base64 of `{"`).
    Static admin tokens are URL-safe random bytes, never that prefix."""
    return token.startswith("eyJ")


# Sprint 46: public alias for the internal JWT decoder, used by the
# WebSocket auth helper (_ws_authenticate in service.py).  Callers must
# supply a live ClerkValidator instance; the function just delegates to
# its validate() method and returns the raw claims dict.
def _verify_session_token(token: str, *, validator: "ClerkValidator") -> dict:
    """Decode and verify a Clerk session JWT using *validator*.

    Raises on any failure (signature invalid, token expired, etc.).
    Returns the raw claims dict so callers can extract ``sub`` etc.

    Example::

        claims = _verify_session_token(token, validator=state["clerk_validator"])
        user_id = claims.get("sub") or "anon"
    """
    import jwt as _jwt
    signing_key = validator._jwks().get_signing_key_from_jwt(token).key
    claims = _jwt.decode(
        token,
        signing_key,
        algorithms=["RS256"],
        issuer=validator.issuer,
        options={"verify_aud": False},
    )
    return claims
