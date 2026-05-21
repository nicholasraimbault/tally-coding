"""Sprint 47: role resolution + permission predicates."""
from tally_orchestrator.channels import (
    resolve_effective_role,
    can_post_in_channel,
    can_dispatch_task,
    can_manage_members,
)


def test_owner_resolution_no_override(db):
    db._conn.execute("INSERT INTO workspaces (name, owner_user_id, plan_slug, created_at) VALUES ('w', 'u1', 'free', 0)")
    ws_id = db._conn.execute("SELECT id FROM workspaces WHERE owner_user_id='u1'").fetchone()[0]
    db._conn.execute("INSERT INTO workspace_members (workspace_id, member_kind, user_id, role, joined_at) VALUES (?, 'human', 'u1', 'owner', 0)", (ws_id,))
    db._conn.execute("INSERT INTO channels (workspace_id, kind, name, created_at) VALUES (?, 'general', 'general', 0)", (ws_id,))
    ch_id = db._conn.execute("SELECT id FROM channels WHERE workspace_id=?", (ws_id,)).fetchone()[0]
    db._conn.execute("INSERT INTO channel_members (channel_id, member_kind, user_id, joined_at) VALUES (?, 'human', 'u1', 0)", (ch_id,))

    role = resolve_effective_role(db, channel_id=ch_id, user_id="u1")
    assert role == "owner"


def test_channel_override_promotes_member(db):
    db._conn.execute("INSERT INTO workspaces (name, owner_user_id, plan_slug, created_at) VALUES ('w', 'u1', 'free', 0)")
    ws_id = db._conn.execute("SELECT id FROM workspaces").fetchone()[0]
    db._conn.execute("INSERT INTO workspace_members (workspace_id, member_kind, user_id, role, joined_at) VALUES (?, 'human', 'u2', 'member', 0)", (ws_id,))
    db._conn.execute("INSERT INTO channels (workspace_id, kind, name, created_at) VALUES (?, 'custom', 'sec', 0)", (ws_id,))
    ch_id = db._conn.execute("SELECT id FROM channels").fetchone()[0]
    db._conn.execute("INSERT INTO channel_members (channel_id, member_kind, user_id, role_override, joined_at) VALUES (?, 'human', 'u2', 'channel_admin', 0)", (ch_id,))

    role = resolve_effective_role(db, channel_id=ch_id, user_id="u2")
    assert role == "channel_admin"


def test_non_member_resolution_none(db):
    db._conn.execute("INSERT INTO workspaces (name, owner_user_id, plan_slug, created_at) VALUES ('w', 'u1', 'free', 0)")
    ws_id = db._conn.execute("SELECT id FROM workspaces").fetchone()[0]
    db._conn.execute("INSERT INTO channels (workspace_id, kind, name, created_at) VALUES (?, 'general', 'g', 0)", (ws_id,))
    ch_id = db._conn.execute("SELECT id FROM channels").fetchone()[0]

    role = resolve_effective_role(db, channel_id=ch_id, user_id="stranger")
    assert role is None


def test_can_post_member_yes_read_only_no(db):
    assert can_post_in_channel("owner") is True
    assert can_post_in_channel("admin") is True
    assert can_post_in_channel("manager") is True
    assert can_post_in_channel("member") is True
    assert can_post_in_channel("channel_admin") is True
    assert can_post_in_channel("read_only") is False
    assert can_post_in_channel(None) is False


def test_can_dispatch_task_member_or_above(db):
    assert can_dispatch_task("owner") is True
    assert can_dispatch_task("admin") is True
    assert can_dispatch_task("manager") is True
    assert can_dispatch_task("member") is True
    assert can_dispatch_task("read_only") is False
    assert can_dispatch_task(None) is False


def test_can_manage_members_admin_only(db):
    assert can_manage_members("owner") is True
    assert can_manage_members("admin") is True
    assert can_manage_members("manager") is False
    assert can_manage_members("member") is False
    assert can_manage_members("channel_admin") is False
    assert can_manage_members(None) is False
