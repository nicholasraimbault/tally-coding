"""Integration tests for Tally Workers HTTP client.

Run against the existing Tally Workers deployment at
https://tally.nraimbault16.workers.dev (canonical resting state).
"""

import os
import uuid

import pytest

from tally_coding_core.identity import bearer_from_pubkey, load_or_create_identity
from tally_coding_core.tally_workers import TallyWorkersClient


TALLY_URL = os.environ.get("TALLY_WORKERS_URL", "https://tally.nraimbault16.workers.dev")


@pytest.fixture
def client():
    return TallyWorkersClient(base_url=TALLY_URL)


@pytest.fixture
def test_team_id():
    """Unique team_id per test run."""
    return f"tally-coding-test-{uuid.uuid4().hex[:8]}"


@pytest.fixture
def test_agent():
    """Per-test ephemeral identity."""
    tmp = f"/tmp/tally-test-identity-{uuid.uuid4().hex[:8]}.key"
    privkey, pubkey = load_or_create_identity(tmp)
    bearer = bearer_from_pubkey(pubkey)
    return {"privkey": privkey, "pubkey": pubkey, "bearer": bearer}


def test_health_endpoint(client):
    """GET /v1/health returns 200 OK."""
    result = client.health()
    assert result["status"] == "ok"
    assert "version" in result


def test_team_init_idempotent(client, test_team_id, test_agent):
    """POST /v1/teams/{id}/init twice returns the same initialized_at."""
    first = client.team_init(test_team_id, bearer=test_agent["bearer"])
    second = client.team_init(test_team_id, bearer=test_agent["bearer"])
    assert first["initialized_at"] == second["initialized_at"]


def test_register_handler(client, test_team_id, test_agent):
    """POST /v1/teams/{id}/agents/{ident}/register works."""
    client.team_init(test_team_id, bearer=test_agent["bearer"])
    result = client.register(
        team_id=test_team_id,
        identity_b64=test_agent["bearer"],
        bearer=test_agent["bearer"],
        context_id="test-context",
    )
    assert result["registered"] is True
    assert result["context_id"] == "test-context"


def test_team_delete_cleans_up(client, test_team_id, test_agent):
    """DELETE /v1/teams/{id} succeeds."""
    client.team_init(test_team_id, bearer=test_agent["bearer"])
    client.team_delete(test_team_id, bearer=test_agent["bearer"])
    # No assert; just confirm no exception
