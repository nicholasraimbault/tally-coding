"""Sprint 51: each Sprint 49-50 mutating route inserts an audit row."""
import pytest
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


def _audit_kinds(svc_module, workspace_id) -> list[str]:
    db = svc_module.state["db"]
    return [r[0] for r in db._conn.execute(
        "SELECT kind FROM workspace_audit_log WHERE workspace_id=? ORDER BY id DESC",
        (workspace_id,),
    ).fetchall()]


def test_workspace_created_audit(client):
    import tally_orchestrator.service as svc
    r = client.post("/workspaces", json={"name": "auditable"})
    assert r.status_code == 200
    wid = r.json()["id"]
    assert "workspace_created" in _audit_kinds(svc, wid)


def test_workspace_renamed_audit(client):
    import tally_orchestrator.service as svc
    r = client.post("/workspaces", json={"name": "old"})
    assert r.status_code == 200
    wid = r.json()["id"]
    client.patch(f"/workspaces/{wid}", json={"name": "new"})
    assert "workspace_renamed" in _audit_kinds(svc, wid)


def test_workspace_settings_updated_audit(client):
    import tally_orchestrator.service as svc
    r = client.post("/workspaces", json={"name": "x"})
    assert r.status_code == 200
    wid = r.json()["id"]
    client.patch(f"/workspaces/{wid}", json={"settings": {"icon_url": "https://a/b"}})
    assert "workspace_settings_updated" in _audit_kinds(svc, wid)


def test_member_invited_audit(client):
    import tally_orchestrator.service as svc
    r = client.post("/workspaces", json={"name": "membertest"})
    assert r.status_code == 200
    wid = r.json()["id"]
    client.post(f"/workspaces/{wid}/members", json={"user_id": "bob", "role": "member"})
    assert "member_invited" in _audit_kinds(svc, wid)


def test_member_removed_audit(client):
    import tally_orchestrator.service as svc
    r = client.post("/workspaces", json={"name": "rmtest"})
    assert r.status_code == 200
    wid = r.json()["id"]
    client.post(f"/workspaces/{wid}/members", json={"user_id": "bob", "role": "member"})
    client.delete(f"/workspaces/{wid}/members/bob")
    assert "member_removed" in _audit_kinds(svc, wid)


def test_member_role_changed_audit(client):
    import tally_orchestrator.service as svc
    r = client.post("/workspaces", json={"name": "roletest"})
    assert r.status_code == 200
    wid = r.json()["id"]
    client.post(f"/workspaces/{wid}/members", json={"user_id": "bob", "role": "member"})
    client.patch(f"/workspaces/{wid}/members/bob", json={"role": "admin"})
    assert "member_role_changed" in _audit_kinds(svc, wid)


def test_custom_channel_created_audit(client):
    import tally_orchestrator.service as svc
    r = client.post("/workspaces", json={"name": "chantest"})
    assert r.status_code == 200
    wid = r.json()["id"]
    client.post("/channels", json={
        "workspace_id": wid, "kind": "custom", "name": "x",
        "members": [{"kind": "human", "id": "admin"}],
    })
    assert "channel_created" in _audit_kinds(svc, wid)


def test_persistent_agent_created_audit(client):
    import tally_orchestrator.service as svc
    r = client.post("/workspaces", json={"name": "patest"})
    assert r.status_code == 200
    wid = r.json()["id"]
    client.post("/persistent_agents", json={
        "workspace_id": wid, "name": "x", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    assert "persistent_agent_created" in _audit_kinds(svc, wid)


def test_persistent_agent_enabled_toggled_audit(client):
    import tally_orchestrator.service as svc
    r = client.post("/workspaces", json={"name": "patoggle"})
    assert r.status_code == 200
    wid = r.json()["id"]
    rp = client.post("/persistent_agents", json={
        "workspace_id": wid, "name": "x", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    pid = rp.json()["id"]
    client.patch(f"/persistent_agents/{pid}", json={"enabled": False})
    assert "persistent_agent_enabled_toggled" in _audit_kinds(svc, wid)


def test_persistent_agent_deleted_audit(client):
    import tally_orchestrator.service as svc
    r = client.post("/workspaces", json={"name": "padel"})
    assert r.status_code == 200
    wid = r.json()["id"]
    rp = client.post("/persistent_agents", json={
        "workspace_id": wid, "name": "x", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    pid = rp.json()["id"]
    client.delete(f"/persistent_agents/{pid}")
    assert "persistent_agent_deleted" in _audit_kinds(svc, wid)


def test_delete_persistent_agent_archives_channel(client):
    """Sprint 51: deleting a persistent agent also archives its scheduled_agent channel."""
    import tally_orchestrator.service as svc
    r = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "x", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    pid = r.json()["id"]
    client.delete(f"/persistent_agents/{pid}")
    db = svc.state["db"]
    row = db._conn.execute(
        "SELECT archived_at FROM channels WHERE persistent_agent_id=?", (pid,)
    ).fetchone()
    assert row is not None
    assert row[0] is not None


def test_auto_pause_emits_system_audit(client):
    """When bump_persistent_agent_failure hits 3, emit persistent_agent_auto_paused audit with actor_kind='system'."""
    import tally_orchestrator.service as svc
    r = client.post("/persistent_agents", json={
        "workspace_id": 1, "name": "flaky-agent", "role_name": "Tester",
        "team_spec": {"nodes": [], "edges": []},
    })
    pid = r.json()["id"]
    db = svc.state["db"]
    for _ in range(3):
        db.bump_persistent_agent_failure(pid)
    row = db._conn.execute(
        "SELECT kind, actor_kind, payload_json FROM workspace_audit_log "
        "WHERE workspace_id=1 AND kind='persistent_agent_auto_paused' ORDER BY id DESC LIMIT 1"
    ).fetchone()
    assert row is not None
    assert row[1] == "system"
    import json as _json
    payload = _json.loads(row[2])
    assert payload.get("name") == "flaky-agent"
