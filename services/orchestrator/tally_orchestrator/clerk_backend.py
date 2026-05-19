"""Sprint 38.5: Clerk Backend API client.

Owns the call that fetches a user's GitHub OAuth access token via:

  GET https://api.clerk.com/v1/users/{user_id}/oauth_access_tokens/github

Authenticated with the ``CLERK_SECRET_KEY`` env var (``sk_test_…`` /
``sk_live_…``).  When unset, ``fetch_github_token`` reports the
manager as unconfigured so callers fall through to the PAT path
without raising.

We deliberately do NOT cache the token in process memory:

  - Clerk auto-refreshes long-lived OAuth tokens, but a snapshot in
    our process would drift on rotation.
  - The freshness check on every push is one extra Backend API
    call (~50 ms); negligible vs. ``git push`` round-trip.
"""
from __future__ import annotations

import logging
import os

import httpx

logger = logging.getLogger("tally.clerk_backend")


class ClerkBackendClient:
    """Thin sync wrapper over the Backend API endpoints we actually use.

    Today: one endpoint (oauth-access-token).  Add more methods here
    as we lean on Clerk for more orchestrator-side operations.
    """

    DEFAULT_BASE = "https://api.clerk.com"

    def __init__(self) -> None:
        self.secret_key = os.environ.get("CLERK_SECRET_KEY", "").strip()
        self.base_url = os.environ.get(
            "CLERK_BACKEND_URL", self.DEFAULT_BASE,
        ).rstrip("/")

    @property
    def configured(self) -> bool:
        return self.secret_key.startswith("sk_test_") or self.secret_key.startswith("sk_live_")

    def fetch_github_token(self, user_id: str) -> tuple[str | None, list[str]]:
        """Return ``(token, scopes)`` for the user's GitHub OAuth
        connection, or ``(None, [])`` when:

          - the Backend client isn't configured (no ``CLERK_SECRET_KEY``);
          - the user has no GitHub OAuth connection;
          - Clerk's API errors (logged, swallowed).

        Caller falls back to the stored PAT in any of these cases.
        Never raises — we want push to gracefully degrade, not 500.
        """
        if not self.configured:
            return (None, [])
        url = f"{self.base_url}/v1/users/{user_id}/oauth_access_tokens/github"
        try:
            resp = httpx.get(
                url,
                headers={"Authorization": f"Bearer {self.secret_key}"},
                timeout=10.0,
            )
        except httpx.HTTPError as exc:
            logger.warning("Clerk Backend API call failed: %s", exc)
            return (None, [])
        if resp.status_code == 404:
            # User signed in via another provider; no GitHub connection.
            return (None, [])
        if resp.status_code != 200:
            logger.warning(
                "Clerk Backend API returned %s for %s: %s",
                resp.status_code, user_id, resp.text[:200],
            )
            return (None, [])
        try:
            body = resp.json()
        except Exception as exc:
            logger.warning("Clerk Backend API returned non-JSON: %s", exc)
            return (None, [])
        # Clerk's API returns either a bare list or a PaginatedResourceResponse
        # depending on the API version.  Normalize.
        entries: list = []
        if isinstance(body, list):
            entries = body
        elif isinstance(body, dict):
            entries = body.get("data") or []
        if not entries:
            return (None, [])
        first = entries[0]
        if not isinstance(first, dict):
            return (None, [])
        token = first.get("token")
        scopes_raw = first.get("scopes") or []
        scopes = [s for s in scopes_raw if isinstance(s, str)]
        if not isinstance(token, str) or not token:
            return (None, [])
        return (token, scopes)
