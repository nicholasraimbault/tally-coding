"""Sprint 50: workspace CRUD helpers."""
from tally_orchestrator.service import Db


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
