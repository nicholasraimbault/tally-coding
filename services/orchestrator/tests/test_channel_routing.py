"""Sprint 49: channel routing for persistent-agent tasks."""
import uuid
from tally_orchestrator.service import Db
from tally_orchestrator.channels import resolve_task_channel_id, get_task_channel_id


def test_resolve_task_channel_id_no_persistent_agent_falls_back(db: Db):
    """Sprint 47 behavior preserved: tasks without persistent_agent_id route to their task channel."""
    task_id = db.create_task("test", team_spec={}, user_id="admin")
    db.approve_task(task_id)
    legacy = get_task_channel_id(db, task_id)
    resolved = resolve_task_channel_id(db, task_id)
    assert resolved == legacy
    assert resolved is not None


def test_resolve_task_channel_id_routes_to_scheduled_agent(db: Db):
    """When a task has persistent_agent_id, route to the agent's scheduled_agent channel."""
    pid = db.create_persistent_agent(
        workspace_id=1, name="x", role_name="Tester", team_spec={},
    )
    sa_ch = db._conn.execute(
        "SELECT id FROM channels WHERE persistent_agent_id=? AND kind='scheduled_agent'", (pid,)
    ).fetchone()[0]
    task_id = uuid.uuid4().hex
    db._conn.execute(
        "INSERT INTO tasks (id, description, status, persistent_agent_id, user_id, created_at, updated_at) "
        "VALUES (?, 'x', 'pending', ?, 'admin', 0, 0)",
        (task_id, pid),
    )
    resolved = resolve_task_channel_id(db, task_id)
    assert resolved == sa_ch
