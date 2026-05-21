"""Sprint 47: schema migration adds 5 chat-foundation tables."""
from tally_orchestrator.service import Db


def test_workspace_tables_present(db: Db):
    names = {row[0] for row in db._conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table'"
    )}
    assert {
        "workspaces",
        "workspace_members",
        "channels",
        "channel_members",
        "messages",
    }.issubset(names)


def test_workspaces_columns(db: Db):
    cols = {row[1] for row in db._conn.execute("PRAGMA table_info(workspaces)")}
    assert {"id", "name", "owner_user_id", "plan_slug", "created_at", "settings_json"}.issubset(cols)


def test_workspace_members_columns(db: Db):
    cols = {row[1] for row in db._conn.execute("PRAGMA table_info(workspace_members)")}
    assert {"id", "workspace_id", "member_kind", "user_id", "persistent_agent_id", "role", "joined_at"}.issubset(cols)


def test_channels_columns(db: Db):
    cols = {row[1] for row in db._conn.execute("PRAGMA table_info(channels)")}
    assert {"id", "workspace_id", "kind", "name", "task_id", "persistent_agent_id", "auto_jump_in_for_tally", "created_at", "archived_at"}.issubset(cols)


def test_channel_members_columns(db: Db):
    cols = {row[1] for row in db._conn.execute("PRAGMA table_info(channel_members)")}
    assert {"id", "channel_id", "member_kind", "user_id", "persistent_agent_id", "task_agent_id", "role_override", "joined_at", "last_read_message_id"}.issubset(cols)


def test_messages_columns(db: Db):
    cols = {row[1] for row in db._conn.execute("PRAGMA table_info(messages)")}
    assert {"id", "channel_id", "author_kind", "author_user_id", "author_agent_id", "kind", "payload_json", "reply_to_id", "created_at", "edited_at"}.issubset(cols)


def test_migration_idempotent(tmp_db_path: str):
    """Opening the same DB twice doesn't error on duplicate-table."""
    Db(tmp_db_path)
    Db(tmp_db_path)
    Db(tmp_db_path)


def test_backfill_admin_workspace_created(db: Db):
    """On first Db init, admin user gets a default workspace + owner membership."""
    rows = db._conn.execute(
        "SELECT id, name, owner_user_id FROM workspaces WHERE owner_user_id='admin'"
    ).fetchall()
    assert len(rows) == 1, f"expected 1 admin workspace, got {len(rows)}"
    ws_id, ws_name, owner = rows[0]
    assert owner == "admin"
    assert "admin" in ws_name.lower()

    members = db._conn.execute(
        "SELECT user_id, role FROM workspace_members "
        "WHERE workspace_id=? AND member_kind='human'",
        (ws_id,),
    ).fetchall()
    assert (("admin", "owner")) in [tuple(m) for m in members]


def test_backfill_creates_general_channel(db: Db):
    """Admin workspace gets an auto-created #general channel."""
    rows = db._conn.execute(
        "SELECT c.id, c.name, c.kind FROM channels c "
        "JOIN workspaces w ON c.workspace_id=w.id "
        "WHERE w.owner_user_id='admin' AND c.kind='general'"
    ).fetchall()
    assert len(rows) == 1


def test_backfill_existing_tasks_get_channels(db: Db):
    """Backfill creates channels for approved (pending) tasks that lack them.
    Sprint 48: proposed/cancelled tasks are skipped by backfill."""
    # Simulate legacy prod tasks that are already approved (pending status)
    db.create_task("test task 1", team_spec=None, user_id="admin", status="pending")
    db.create_task("test task 2", team_spec=None, user_id="admin", status="pending")
    # Re-open Db to trigger backfill on the now-populated tasks table
    db2 = db.__class__(db.path)

    # Only pending tasks should get backfilled channels
    pending_cnt = db2._conn.execute("SELECT COUNT(*) FROM tasks WHERE status='pending'").fetchone()[0]
    cnt = db2._conn.execute("SELECT COUNT(*) FROM channels WHERE kind='task'").fetchone()[0]
    assert cnt == pending_cnt, f"expected one channel per pending task; got {cnt} channels for {pending_cnt} pending tasks"

    member_rows = db2._conn.execute(
        "SELECT cm.user_id FROM channel_members cm "
        "JOIN channels c ON cm.channel_id=c.id "
        "WHERE c.kind='task'"
    ).fetchall()
    assert len(member_rows) == pending_cnt, (
        f"expected one channel_members row per task channel; got {len(member_rows)} for {pending_cnt} tasks"
    )
    assert all(row[0] == "admin" for row in member_rows)


def test_agents_iteration_idx_column(db: Db):
    """Sprint 48: agents.iteration_idx column exists (back-edge cycle tracker)."""
    cols = {row[1] for row in db._conn.execute("PRAGMA table_info(agents)").fetchall()}
    assert "iteration_idx" in cols


def test_new_task_creates_task_channel(db: Db):
    """Sprint 48: task channel is inserted on approve_task, not create_task."""
    task_id = db.create_task("test", team_spec={"agents": [{"role": "Coder"}]}, user_id="admin")
    db.approve_task(task_id)
    row = db._conn.execute(
        "SELECT id, kind FROM channels WHERE task_id=?", (task_id,)
    ).fetchone()
    assert row is not None
    assert row[1] == "task"


def test_new_task_creates_task_channel_member(db: Db):
    """The task owner is auto-joined to the task channel on approve."""
    task_id = db.create_task("test", team_spec={"agents": [{"role": "Coder"}]}, user_id="admin")
    db.approve_task(task_id)
    row = db._conn.execute(
        "SELECT cm.user_id FROM channel_members cm "
        "JOIN channels c ON cm.channel_id=c.id "
        "WHERE c.task_id=? AND cm.member_kind='human'",
        (task_id,),
    ).fetchone()
    assert row is not None
    assert row[0] == "admin"


def test_create_task_proposed_no_channel(db: Db):
    """Sprint 48: create_task with status='proposed' (default) creates NO task channel."""
    task_id = db.create_task("test", team_spec={"agents": [{"role": "Coder"}]}, user_id="admin")
    row = db._conn.execute(
        "SELECT id FROM channels WHERE task_id=?", (task_id,)
    ).fetchone()
    assert row is None, "task channel should not exist until approve_task"


def test_approve_task_creates_channel(db: Db):
    """Sprint 48: approve_task transitions status + creates the task channel + owner channel_member."""
    task_id = db.create_task("test", team_spec={"agents": [{"role": "Coder"}]}, user_id="admin")
    db.approve_task(task_id)
    status = db._conn.execute("SELECT status FROM tasks WHERE id=?", (task_id,)).fetchone()[0]
    assert status == "pending"
    row = db._conn.execute(
        "SELECT id, kind FROM channels WHERE task_id=?", (task_id,)
    ).fetchone()
    assert row is not None
    assert row[1] == "task"
    mrow = db._conn.execute(
        "SELECT user_id FROM channel_members cm JOIN channels c ON cm.channel_id=c.id "
        "WHERE c.task_id=?", (task_id,)
    ).fetchone()
    assert mrow is not None
    assert mrow[0] == "admin"


def test_approve_task_idempotent(db: Db):
    """approve_task on a non-proposed task is a no-op (returns silently)."""
    task_id = db.create_task("test", team_spec={"agents": [{"role": "Coder"}]}, user_id="admin")
    db.approve_task(task_id)  # proposed -> pending + creates channel
    # Calling again on pending status: no-op, no duplicate channel
    db.approve_task(task_id)
    cnt = db._conn.execute("SELECT COUNT(*) FROM channels WHERE task_id=?", (task_id,)).fetchone()[0]
    assert cnt == 1


def test_backfill_tally_workspace_member(db: Db):
    """Every workspace has a tally workspace_member after backfill."""
    rows = db._conn.execute(
        "SELECT w.id FROM workspaces w "
        "WHERE NOT EXISTS (SELECT 1 FROM workspace_members wm "
        "                  WHERE wm.workspace_id=w.id AND wm.member_kind='tally')"
    ).fetchall()
    assert rows == []


def test_backfill_tally_in_general_and_backlog(db: Db):
    """Tally is a channel_member of every existing #general and #backlog channel."""
    rows = db._conn.execute(
        "SELECT c.id, c.kind FROM channels c "
        "WHERE c.kind IN ('general', 'backlog') "
        "AND NOT EXISTS (SELECT 1 FROM channel_members cm "
        "                WHERE cm.channel_id=c.id AND cm.member_kind='tally')"
    ).fetchall()
    assert rows == []
