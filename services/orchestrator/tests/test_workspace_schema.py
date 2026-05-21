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
    """Every existing tasks row gets a channels row of kind='task'."""
    # Pre-create some tasks (simulating real prod state)
    db.create_task("test task 1", team_spec=None, user_id="admin")
    db.create_task("test task 2", team_spec=None, user_id="admin")
    # Re-open Db to trigger backfill on the now-populated tasks table
    db2 = db.__class__(db.path)

    cnt = db2._conn.execute("SELECT COUNT(*) FROM channels WHERE kind='task'").fetchone()[0]
    tasks_cnt = db2._conn.execute("SELECT COUNT(*) FROM tasks").fetchone()[0]
    assert cnt == tasks_cnt, f"expected one channel per task; got {cnt} channels for {tasks_cnt} tasks"

    member_rows = db2._conn.execute(
        "SELECT cm.user_id FROM channel_members cm "
        "JOIN channels c ON cm.channel_id=c.id "
        "WHERE c.kind='task'"
    ).fetchall()
    assert len(member_rows) == tasks_cnt, (
        f"expected one channel_members row per task channel; got {len(member_rows)} for {tasks_cnt} tasks"
    )
    assert all(row[0] == "admin" for row in member_rows)
