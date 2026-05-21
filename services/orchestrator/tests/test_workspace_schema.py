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
