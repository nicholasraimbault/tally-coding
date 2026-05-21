"""Sprint 47: agent context inclusion — user messages reach the agent's
next LLM turn via the orchestrator's dispatch path."""
import time
import json
from tally_orchestrator.service import Db
from tally_orchestrator.channels import (
    insert_message, get_task_channel_id, fetch_user_messages_since,
)


def test_get_task_channel_id_after_backfill(db: Db):
    """A task created via the existing path gets a backfilled channel row."""
    task_id = db.create_task("test", team_spec={"agents": [{"role": "Coder"}]}, user_id="admin")
    # Re-run backfill so the task gets a channel (until A12 lands inline)
    db._backfill_workspaces_and_channels()
    ch_id = get_task_channel_id(db, task_id)
    assert ch_id is not None


def test_fetch_user_messages_since(db: Db):
    """Helper returns user messages from a channel since a timestamp."""
    task_id = db.create_task("test", team_spec={"agents": [{"role": "Coder"}]}, user_id="admin")
    db._backfill_workspaces_and_channels()
    ch_id = get_task_channel_id(db, task_id)
    assert ch_id is not None
    insert_message(db, channel_id=ch_id, author_kind="human", author_user_id="admin",
                   kind="text", payload={"text": "intervention 1"})
    # Agent messages are NOT user messages and should be filtered out
    insert_message(db, channel_id=ch_id, author_kind="agent", author_agent_id=None,
                   kind="text", payload={"text": "agent reply"})
    insert_message(db, channel_id=ch_id, author_kind="human", author_user_id="admin",
                   kind="text", payload={"text": "intervention 2"})
    user_msgs = fetch_user_messages_since(db, channel_id=ch_id, since_ts=0)
    assert len(user_msgs) == 2
    assert "intervention 1" in user_msgs[0]["text"]
    assert "intervention 2" in user_msgs[1]["text"]


def test_fetch_user_messages_excludes_old(db: Db):
    """Messages with created_at <= since_ts are excluded."""
    task_id = db.create_task("test", team_spec={"agents": [{"role": "Coder"}]}, user_id="admin")
    db._backfill_workspaces_and_channels()
    ch_id = get_task_channel_id(db, task_id)
    insert_message(db, channel_id=ch_id, author_kind="human", author_user_id="admin",
                   kind="text", payload={"text": "old"})
    time.sleep(0.05)
    cutoff = time.time()
    time.sleep(0.05)
    insert_message(db, channel_id=ch_id, author_kind="human", author_user_id="admin",
                   kind="text", payload={"text": "new"})
    user_msgs = fetch_user_messages_since(db, channel_id=ch_id, since_ts=cutoff)
    assert len(user_msgs) == 1
    assert "new" in user_msgs[0]["text"]
