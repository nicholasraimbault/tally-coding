"""HTTP client for Tally Workers API.

8 public routes per docs/specs/phase-1b-sub-pr-1-phase-0.md §3.3 in the
tally-workers repo. Bearer auth = url_safe_b64(identity_bytes) per the MVP D5
contract.
"""

from __future__ import annotations

from typing import Any

import httpx


class TallyWorkersClient:
    """Synchronous HTTP client for Tally Workers. Use httpx for HTTP/2 + sync API."""

    def __init__(self, base_url: str, timeout_seconds: float = 60.0):
        self.base_url = base_url.rstrip("/")
        self._client = httpx.Client(base_url=self.base_url, timeout=timeout_seconds)

    def __del__(self):
        try:
            self._client.close()
        except Exception:
            pass

    # ─── Health ────────────────────────────────────────────────────────────

    def health(self) -> dict[str, Any]:
        """GET /v1/health"""
        resp = self._client.get("/v1/health")
        resp.raise_for_status()
        return resp.json()

    # ─── Team-administrative ───────────────────────────────────────────────

    def team_init(self, team_id: str, bearer: str) -> dict[str, Any]:
        """POST /v1/teams/{team_id}/init — idempotent provisioning."""
        resp = self._client.post(
            f"/v1/teams/{team_id}/init",
            headers={"Authorization": f"Bearer {bearer}"},
        )
        resp.raise_for_status()
        return resp.json()

    def team_status(self, team_id: str, bearer: str) -> dict[str, Any]:
        """GET /v1/teams/{team_id}/status"""
        resp = self._client.get(
            f"/v1/teams/{team_id}/status",
            headers={"Authorization": f"Bearer {bearer}"},
        )
        resp.raise_for_status()
        return resp.json()

    def team_delete(self, team_id: str, bearer: str) -> None:
        """DELETE /v1/teams/{team_id}"""
        resp = self._client.delete(
            f"/v1/teams/{team_id}",
            headers={"Authorization": f"Bearer {bearer}"},
        )
        resp.raise_for_status()

    # ─── Handler registration ──────────────────────────────────────────────

    def register(
        self,
        team_id: str,
        identity_b64: str,
        bearer: str,
        context_id: str,
        metadata: dict | None = None,
    ) -> dict[str, Any]:
        """POST /v1/teams/{team_id}/agents/{identity}/register"""
        body: dict[str, Any] = {"context_id": context_id}
        if metadata:
            body["metadata"] = metadata
        resp = self._client.post(
            f"/v1/teams/{team_id}/agents/{identity_b64}/register",
            headers={"Authorization": f"Bearer {bearer}"},
            json=body,
        )
        resp.raise_for_status()
        return resp.json()

    def unregister(
        self, team_id: str, identity_b64: str, context_id: str, bearer: str,
    ) -> None:
        """DELETE /v1/teams/{team_id}/agents/{identity}/handlers/{context_id}"""
        resp = self._client.delete(
            f"/v1/teams/{team_id}/agents/{identity_b64}/handlers/{context_id}",
            headers={"Authorization": f"Bearer {bearer}"},
        )
        resp.raise_for_status()

    # ─── Wake dispatch ─────────────────────────────────────────────────────

    def dispatch_wake(
        self,
        team_id: str,
        target_identity: str,
        context_id: str,
        payload: str,  # base64-encoded
        timeout_seconds: int,
        bearer: str,
    ) -> dict[str, Any]:
        """POST /v1/teams/{team_id}/wakes — dispatch + await completion."""
        resp = self._client.post(
            f"/v1/teams/{team_id}/wakes",
            headers={"Authorization": f"Bearer {bearer}"},
            json={
                "target_identity": target_identity,
                "context_id": context_id,
                "payload": payload,
                "timeout_seconds": timeout_seconds,
            },
            timeout=timeout_seconds + 5,
        )
        resp.raise_for_status()
        return resp.json()  # {wake_id, response, completed_at}

    def read_inbox(
        self,
        team_id: str,
        identity_b64: str,
        bearer: str,
        wait_seconds: int | None = 30,
        limit: int | None = 10,
    ) -> dict[str, Any]:
        """GET /v1/teams/{team_id}/agents/{identity}/inbox"""
        params: dict[str, int] = {}
        if wait_seconds is not None:
            params["wait_seconds"] = wait_seconds
        if limit is not None:
            params["limit"] = limit
        resp = self._client.get(
            f"/v1/teams/{team_id}/agents/{identity_b64}/inbox",
            headers={"Authorization": f"Bearer {bearer}"},
            params=params,
            timeout=(wait_seconds or 30) + 10,
        )
        resp.raise_for_status()
        return resp.json()  # {wakes: [...], more_available: bool}

    def complete_wake(
        self,
        team_id: str,
        wake_id: str,
        response_payload: str,  # base64-encoded
        bearer: str,
    ) -> dict[str, Any]:
        """POST /v1/teams/{team_id}/wakes/{wake_id}/complete"""
        resp = self._client.post(
            f"/v1/teams/{team_id}/wakes/{wake_id}/complete",
            headers={"Authorization": f"Bearer {bearer}"},
            json={"response": response_payload},
        )
        resp.raise_for_status()
        return resp.json()  # {completed, wake_id}
