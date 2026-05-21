"""Sprint 50: workspace CRUD helpers + POST /workspaces HTTP route."""
import pytest
from fastapi.testclient import TestClient

from tally_orchestrator.service import Db


# ── HTTP route fixture ─────────────────────────────────────────────────────────


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


# ── POST /workspaces tests ─────────────────────────────────────────────────────


def test_post_workspace_returns_id(client):
    r = client.post("/workspaces", json={"name": "My New Workspace"})
    assert r.status_code == 200
    body = r.json()
    assert body["name"] == "My New Workspace"
    assert body["id"] > 0
    assert body.get("role") == "owner"


def test_post_workspace_creates_general_backlog(client):
    import tally_orchestrator.service as svc
    r = client.post("/workspaces", json={"name": "W"})
    wid = r.json()["id"]
    db = svc.state["db"]
    kinds = {row[0] for row in db._conn.execute(
        "SELECT kind FROM channels WHERE workspace_id=?", (wid,)
    ).fetchall()}
    assert {"general", "backlog"}.issubset(kinds)


def test_post_workspace_enforces_20_cap(client):
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    # The Db backfill always creates 1 workspace for "admin".
    # Seed 18 more directly to bring the total to 19.
    for i in range(18):
        db.create_workspace(name=f"seeded-{i}", owner_user_id="admin")
    # 20th via HTTP must succeed (fills the cap exactly)
    r = client.post("/workspaces", json={"name": "20th"})
    assert r.status_code == 200
    # 21st must fail with 429 workspace_limit
    r = client.post("/workspaces", json={"name": "21st"})
    assert r.status_code == 429
    body = r.json()
    assert body["detail"]["error"] == "workspace_limit"
    assert body["detail"]["limit"] == 20


# ── Db-level unit tests ────────────────────────────────────────────────────────


def test_create_workspace_returns_id(db: Db):
    wid = db.create_workspace(name="My Team", owner_user_id="alice")
    assert isinstance(wid, int) and wid > 0


def test_create_workspace_creates_general_and_backlog(db: Db):
    wid = db.create_workspace(name="My Team", owner_user_id="alice")
    kinds = {r[0] for r in db._conn.execute(
        "SELECT kind FROM channels WHERE workspace_id=?", (wid,)
    ).fetchall()}
    assert {"general", "backlog"}.issubset(kinds)


def test_create_workspace_adds_owner_and_tally_workspace_members(db: Db):
    wid = db.create_workspace(name="My Team", owner_user_id="alice")
    rows = db._conn.execute(
        "SELECT member_kind, user_id, role FROM workspace_members WHERE workspace_id=?", (wid,)
    ).fetchall()
    member_set = {(m, u, r) for m, u, r in rows}
    assert ("human", "alice", "owner") in member_set
    assert any(m == "tally" for m, _, _ in member_set)


def test_create_workspace_adds_tally_to_general_and_backlog(db: Db):
    wid = db.create_workspace(name="My Team", owner_user_id="alice")
    for kind in ("general", "backlog"):
        ch_id = db._conn.execute(
            "SELECT id FROM channels WHERE workspace_id=? AND kind=?", (wid, kind)
        ).fetchone()[0]
        members = {r[0] for r in db._conn.execute(
            "SELECT member_kind FROM channel_members WHERE channel_id=?", (ch_id,)
        ).fetchall()}
        assert "human" in members
        assert "tally" in members


# ── GET /me/workspaces tests ───────────────────────────────────────────────────


def test_get_me_workspaces_returns_caller_memberships(client):
    client.post("/workspaces", json={"name": "W2"})
    client.post("/workspaces", json={"name": "W3"})
    r = client.get("/me/workspaces")
    assert r.status_code == 200
    body = r.json()
    # admin has 1 from backfill + 2 just created
    assert len(body["workspaces"]) == 3
    names = {w["name"] for w in body["workspaces"]}
    assert "W2" in names
    assert "W3" in names
    assert all("role" in w and "id" in w for w in body["workspaces"])


def test_get_me_workspaces_skips_deleted(client):
    import tally_orchestrator.service as svc
    r = client.post("/workspaces", json={"name": "deleted-soon"})
    wid = r.json()["id"]
    svc.state["db"]._conn.execute(
        "UPDATE workspaces SET deleted_at=? WHERE id=?", (1.0, wid)
    )
    r = client.get("/me/workspaces")
    assert not any(w["id"] == wid for w in r.json()["workspaces"])
