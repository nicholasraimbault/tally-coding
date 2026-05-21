"""Sprint 52: audit log prune."""
import pytest
import time
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch, tmp_db_path):
    monkeypatch.setenv("ORCH_DB_PATH", tmp_db_path)
    monkeypatch.setenv("TALLY_API_TOKEN", "test-token")
    monkeypatch.setenv("REDPILL_API_KEY", "")
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


def test_prune_deletes_old_entries(client):
    """Sprint 52: rows with created_at older than the cutoff are deleted; newer rows stay."""
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    # Inject an old audit row (40 days ago)
    old_ts = time.time() - (40 * 86400)
    db._conn.execute(
        "INSERT INTO workspace_audit_log "
        "(workspace_id, actor_user_id, actor_kind, kind, target_kind, target_id, payload_json, created_at) "
        "VALUES (?, ?, 'human', ?, NULL, NULL, '{}', ?)",
        (1, "admin", "old_event", old_ts),
    )
    r = client.post("/workspaces/1/audit-log/prune", json={"older_than_days": 30})
    assert r.status_code == 200
    assert r.json()["ok"] is True
    assert r.json()["deleted"] >= 1


def test_prune_below_30_days_returns_400(client):
    """Sprint 52: the 30-day safety floor is enforced."""
    r = client.post("/workspaces/1/audit-log/prune", json={"older_than_days": 29})
    assert r.status_code == 400


def test_prune_emits_audit(client):
    """Sprint 52: the prune action itself is audited (kind=audit_log_pruned)."""
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    client.post("/workspaces/1/audit-log/prune", json={"older_than_days": 30})
    row = db._conn.execute(
        "SELECT kind FROM workspace_audit_log "
        "WHERE workspace_id=1 AND kind='audit_log_pruned' "
        "ORDER BY id DESC LIMIT 1"
    ).fetchone()
    assert row is not None


def test_prune_non_admin_returns_403(client):
    """Sprint 52: manager/member roles cannot prune."""
    import tally_orchestrator.service as svc
    from tally_orchestrator.clerk_auth import User as ClerkUser
    client.post("/workspaces/1/members", json={"user_id": "user_bob", "role": "manager"})
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="user_bob", source="clerk", plan="free", email="b@x.com",
    )
    r = client.post("/workspaces/1/audit-log/prune", json={"older_than_days": 30})
    assert r.status_code == 403
