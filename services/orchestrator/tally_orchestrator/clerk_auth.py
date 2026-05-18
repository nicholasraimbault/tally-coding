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
    """
    id: str
    source: str          # "clerk" | "admin"
    email: str | None = None
    github: str | None = None


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
        return User(
            id=sub,
            source="clerk",
            email=email if isinstance(email, str) else None,
            github=github if isinstance(github, str) else None,
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
