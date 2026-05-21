"""Sprint 49: Db helpers for persistent_agents."""
import json
from tally_orchestrator.service import Db


def test_create_persistent_agent_returns_id(db: Db):
    pid = db.create_persistent_agent(
        workspace_id=1,
        name="nightly-tests",
        role_name="Tester",
        team_spec={"nodes": [{"id": "n1", "kind": "agent", "role": "Tester"}], "edges": [], "format": "nodes_v1"},
        cron_schedule="0 21 * * *",
    )
    assert isinstance(pid, int) and pid > 0


def test_create_persistent_agent_creates_scheduled_agent_channel(db: Db):
    pid = db.create_persistent_agent(
        workspace_id=1, name="nightly", role_name="Tester",
        team_spec={"nodes": [], "edges": []},
    )
    row = db._conn.execute(
        "SELECT id, name, kind FROM channels WHERE persistent_agent_id=?", (pid,)
    ).fetchone()
    assert row is not None
    assert row[2] == "scheduled_agent"


def test_create_persistent_agent_adds_owner_and_tally_as_members(db: Db):
    pid = db.create_persistent_agent(
        workspace_id=1, name="nightly", role_name="Tester",
        team_spec={"nodes": [], "edges": []},
    )
    ch_id = db._conn.execute(
        "SELECT id FROM channels WHERE persistent_agent_id=?", (pid,)
    ).fetchone()[0]
    member_kinds = {r[0] for r in db._conn.execute(
        "SELECT member_kind FROM channel_members WHERE channel_id=?", (ch_id,)
    ).fetchall()}
    assert "human" in member_kinds  # owner
    assert "tally" in member_kinds


def test_create_persistent_agent_computes_next_scheduled_run(db: Db):
    pid = db.create_persistent_agent(
        workspace_id=1, name="nightly", role_name="Tester",
        team_spec={"nodes": [], "edges": []},
        cron_schedule="0 21 * * *",
    )
    row = db._conn.execute(
        "SELECT next_scheduled_run_at FROM persistent_agents WHERE id=?", (pid,)
    ).fetchone()
    assert row[0] is not None and row[0] > 0


def test_list_persistent_agents(db: Db):
    db.create_persistent_agent(workspace_id=1, name="a", role_name="Tester", team_spec={})
    db.create_persistent_agent(workspace_id=1, name="b", role_name="Tester", team_spec={})
    rows = db.list_persistent_agents(workspace_id=1)
    names = {r["name"] for r in rows}
    assert {"a", "b"}.issubset(names)


def test_update_persistent_agent(db: Db):
    pid = db.create_persistent_agent(workspace_id=1, name="a", role_name="Tester", team_spec={})
    db.update_persistent_agent(pid, patch={"name": "renamed", "enabled": 0})
    row = db._conn.execute(
        "SELECT name, enabled FROM persistent_agents WHERE id=?", (pid,)
    ).fetchone()
    assert row[0] == "renamed"
    assert row[1] == 0


def test_delete_persistent_agent_soft(db: Db):
    pid = db.create_persistent_agent(workspace_id=1, name="a", role_name="Tester", team_spec={})
    db.delete_persistent_agent(pid)
    row = db._conn.execute(
        "SELECT deleted_at FROM persistent_agents WHERE id=?", (pid,)
    ).fetchone()
    assert row[0] is not None
    rows = db.list_persistent_agents(workspace_id=1)
    assert all(r["id"] != pid for r in rows)
