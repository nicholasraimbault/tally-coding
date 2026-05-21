"""Sprint 52: Clerk user validation helper."""
import pytest
from unittest.mock import patch


@pytest.mark.asyncio
async def test_validate_skip_when_unset(monkeypatch):
    from tally_orchestrator.service import _validate_clerk_user
    monkeypatch.delenv("CLERK_SECRET_KEY", raising=False)
    result = await _validate_clerk_user("user_123")
    assert result is None


@pytest.mark.asyncio
async def test_validate_200_returns_true(monkeypatch):
    from tally_orchestrator.service import _validate_clerk_user
    monkeypatch.setenv("CLERK_SECRET_KEY", "sk_test_xxx")

    class FakeResp:
        status_code = 200

    class FakeClient:
        async def __aenter__(self): return self
        async def __aexit__(self, *a): return False
        async def get(self, url, headers=None):
            return FakeResp()

    with patch("httpx.AsyncClient", return_value=FakeClient()):
        result = await _validate_clerk_user("user_123")
    assert result is True


@pytest.mark.asyncio
async def test_validate_404_returns_false(monkeypatch):
    from tally_orchestrator.service import _validate_clerk_user
    monkeypatch.setenv("CLERK_SECRET_KEY", "sk_test_xxx")

    class FakeResp:
        status_code = 404

    class FakeClient:
        async def __aenter__(self): return self
        async def __aexit__(self, *a): return False
        async def get(self, url, headers=None):
            return FakeResp()

    with patch("httpx.AsyncClient", return_value=FakeClient()):
        result = await _validate_clerk_user("user_123")
    assert result is False


@pytest.mark.asyncio
async def test_validate_500_skips_gracefully(monkeypatch):
    from tally_orchestrator.service import _validate_clerk_user
    monkeypatch.setenv("CLERK_SECRET_KEY", "sk_test_xxx")

    class FakeResp:
        status_code = 500

    class FakeClient:
        async def __aenter__(self): return self
        async def __aexit__(self, *a): return False
        async def get(self, url, headers=None):
            return FakeResp()

    with patch("httpx.AsyncClient", return_value=FakeClient()):
        result = await _validate_clerk_user("user_123")
    assert result is None


@pytest.mark.asyncio
async def test_validate_exception_skips_gracefully(monkeypatch):
    from tally_orchestrator.service import _validate_clerk_user
    monkeypatch.setenv("CLERK_SECRET_KEY", "sk_test_xxx")

    class FailingClient:
        async def __aenter__(self): return self
        async def __aexit__(self, *a): return False
        async def get(self, url, headers=None):
            raise Exception("network down")

    with patch("httpx.AsyncClient", return_value=FailingClient()):
        result = await _validate_clerk_user("user_123")
    assert result is None


@pytest.mark.asyncio
async def test_validate_rejects_path_traversal(monkeypatch):
    """Sprint 52 hardening: a user_id containing path separators is rejected
    BEFORE the HTTP call, so an attacker cannot redirect the request to a
    different Clerk endpoint via `user_x/../organizations`."""
    from tally_orchestrator.service import _validate_clerk_user
    monkeypatch.setenv("CLERK_SECRET_KEY", "sk_test_xxx")
    # patch httpx so any actual call would crash the test loudly
    with patch("httpx.AsyncClient", side_effect=AssertionError("httpx must NOT be called")):
        result = await _validate_clerk_user("user_x/../organizations")
    assert result is False


@pytest.mark.asyncio
async def test_validate_rejects_query_injection(monkeypatch):
    """Sprint 52 hardening: a user_id containing `?` or `#` would change the
    URL semantics and is rejected before the HTTP call."""
    from tally_orchestrator.service import _validate_clerk_user
    monkeypatch.setenv("CLERK_SECRET_KEY", "sk_test_xxx")
    with patch("httpx.AsyncClient", side_effect=AssertionError("httpx must NOT be called")):
        r1 = await _validate_clerk_user("user_x?foo=1")
        r2 = await _validate_clerk_user("user_x#frag")
    assert r1 is False
    assert r2 is False


# ── Invite route integration ───────────────────────────────────────────────────

import pytest as _pytest
from fastapi.testclient import TestClient


@_pytest.fixture
def client(monkeypatch, tmp_db_path):
    monkeypatch.setenv("ORCH_DB_PATH", tmp_db_path)
    monkeypatch.setenv("TALLY_API_TOKEN", "test-token")
    monkeypatch.setenv("REDPILL_API_KEY", "")
    monkeypatch.delenv("CLERK_SECRET_KEY", raising=False)
    import importlib
    import tally_orchestrator.service as svc
    importlib.reload(svc)

    db = svc.Db(tmp_db_path)
    event_bus = svc.EventBus()
    orchestrator = svc.Orchestrator(
        tally_url="http://localhost:9999",
        identity_path=tmp_db_path + ".orch.key",
        mls_state_base_dir=tmp_db_path + ".mls",
        db=db,
        event_bus=event_bus,
    )
    orchestrator.redpill_key = None
    svc.state["db"] = db
    svc.state["orchestrator"] = orchestrator
    svc.state["event_bus"] = event_bus
    svc.state["api_token"] = "test-token"
    svc.state["pool_ready"] = True
    svc.state["pool_status"] = {"target_size": 0, "joined": 0, "last_error": None}

    from tally_orchestrator.clerk_auth import User as ClerkUser
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="admin", source="admin", plan="unlimited", email="admin@x.com",
    )
    yield TestClient(svc.app)
    svc.app.dependency_overrides.clear()


def test_invite_route_404_when_clerk_says_not_found(client, monkeypatch):
    """Sprint 52: POST /workspaces/{id}/members returns 404 when Clerk reports the user doesn't exist."""
    monkeypatch.setenv("CLERK_SECRET_KEY", "sk_test_xxx")

    class FakeResp:
        status_code = 404

    class FakeClient:
        async def __aenter__(self): return self
        async def __aexit__(self, *a): return False
        async def get(self, url, headers=None):
            return FakeResp()

    with patch("httpx.AsyncClient", return_value=FakeClient()):
        r = client.post("/workspaces/1/members", json={"user_id": "user_fake", "role": "member"})
    assert r.status_code == 404
    body = r.json()
    assert body["detail"]["error"] == "user_not_found"
    assert body["detail"]["user_id"] == "user_fake"


def test_invite_route_succeeds_when_clerk_unset(client, monkeypatch):
    """Sprint 52: when CLERK_SECRET_KEY is unset, invite trusts the caller (existing Sprint 50 behavior)."""
    monkeypatch.delenv("CLERK_SECRET_KEY", raising=False)
    r = client.post("/workspaces/1/members", json={"user_id": "user_bob", "role": "member"})
    assert r.status_code == 200


def test_invite_route_succeeds_when_clerk_validates(client, monkeypatch):
    """Sprint 52: when Clerk returns 200, the invite proceeds normally."""
    monkeypatch.setenv("CLERK_SECRET_KEY", "sk_test_xxx")

    class FakeResp:
        status_code = 200

    class FakeClient:
        async def __aenter__(self): return self
        async def __aexit__(self, *a): return False
        async def get(self, url, headers=None):
            return FakeResp()

    with patch("httpx.AsyncClient", return_value=FakeClient()):
        r = client.post("/workspaces/1/members", json={"user_id": "user_alice", "role": "member"})
    assert r.status_code == 200
