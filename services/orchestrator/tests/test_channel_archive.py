"""Sprint 51: channel archive/unarchive."""
import importlib

import pytest
from fastapi.testclient import TestClient


# ── Fixture ────────────────────────────────────────────────────────────────────


@pytest.fixture
def client(monkeypatch, tmp_db_path):
    monkeypatch.setenv("ORCH_DB_PATH", tmp_db_path)
    monkeypatch.setenv("TALLY_API_TOKEN", "test-token")
    monkeypatch.setenv("REDPILL_API_KEY", "")
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
    # Ensure workspace 1 exists (the backfill creates it for "admin")
    yield TestClient(svc.app)
    svc.app.dependency_overrides.clear()


# ── Helpers ────────────────────────────────────────────────────────────────────


def _make_custom_channel(client) -> int:
    r = client.post("/channels", json={
        "workspace_id": 1, "kind": "custom", "name": "test",
        "members": [{"kind": "human", "id": "admin"}],
    })
    assert r.status_code == 200, r.text
    return r.json()["id"]


# ── Tests ──────────────────────────────────────────────────────────────────────


def test_archive_custom_channel_succeeds(client):
    import tally_orchestrator.service as svc
    ch_id = _make_custom_channel(client)
    r = client.post(f"/channels/{ch_id}/archive")
    assert r.status_code == 200
    row = svc.state["db"]._conn.execute(
        "SELECT archived_at FROM channels WHERE id=?", (ch_id,)
    ).fetchone()
    assert row[0] is not None


def test_archive_general_channel_returns_400(client):
    """Cannot archive general/backlog/dm/scheduled_agent channels."""
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    # find admin's general channel
    ch_id = db._conn.execute(
        "SELECT c.id FROM channels c JOIN workspaces w ON c.workspace_id=w.id "
        "WHERE w.owner_user_id='admin' AND c.kind='general' LIMIT 1"
    ).fetchone()[0]
    r = client.post(f"/channels/{ch_id}/archive")
    assert r.status_code == 400


def test_archive_non_admin_returns_403(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    ch_id = _make_custom_channel(client)
    client.post("/workspaces/1/members", json={"user_id": "bob", "role": "member"})
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="bob", source="clerk", plan="free", email="b@x.com",
    )
    r = client.post(f"/channels/{ch_id}/archive")
    assert r.status_code == 403


def test_unarchive_succeeds(client):
    import tally_orchestrator.service as svc
    ch_id = _make_custom_channel(client)
    client.post(f"/channels/{ch_id}/archive")
    r = client.post(f"/channels/{ch_id}/unarchive")
    assert r.status_code == 200
    row = svc.state["db"]._conn.execute(
        "SELECT archived_at FROM channels WHERE id=?", (ch_id,)
    ).fetchone()
    assert row[0] is None


def test_archive_emits_audit(client):
    import tally_orchestrator.service as svc
    ch_id = _make_custom_channel(client)
    client.post(f"/channels/{ch_id}/archive")
    db = svc.state["db"]
    row = db._conn.execute(
        "SELECT kind FROM workspace_audit_log "
        "WHERE workspace_id=1 AND kind='channel_archived' ORDER BY id DESC LIMIT 1"
    ).fetchone()
    assert row is not None


def test_unarchive_emits_audit(client):
    import tally_orchestrator.service as svc
    ch_id = _make_custom_channel(client)
    client.post(f"/channels/{ch_id}/archive")
    client.post(f"/channels/{ch_id}/unarchive")
    db = svc.state["db"]
    row = db._conn.execute(
        "SELECT kind FROM workspace_audit_log "
        "WHERE workspace_id=1 AND kind='channel_unarchived' ORDER BY id DESC LIMIT 1"
    ).fetchone()
    assert row is not None
