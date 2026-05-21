"""Sprint 49: persistent_agents table presence + columns."""
from tally_orchestrator.service import Db


def test_persistent_agents_table_present(db: Db):
    row = db._conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='persistent_agents'"
    ).fetchone()
    assert row is not None


def test_persistent_agents_columns(db: Db):
    cols = {r[1]: r[2] for r in db._conn.execute("PRAGMA table_info(persistent_agents)").fetchall()}
    expected = {
        "id", "workspace_id", "name", "role_name", "team_spec_json",
        "tool_allowlist_json", "model", "cron_schedule", "event_triggers_json",
        "enabled", "last_run_at", "next_scheduled_run_at", "consecutive_failures",
        "created_at", "deleted_at",
    }
    assert expected.issubset(set(cols.keys()))


def test_persistent_agents_index(db: Db):
    idxs = {r[1] for r in db._conn.execute("PRAGMA index_list('persistent_agents')").fetchall()}
    assert "idx_persistent_agents" in idxs
