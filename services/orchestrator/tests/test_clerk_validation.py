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
