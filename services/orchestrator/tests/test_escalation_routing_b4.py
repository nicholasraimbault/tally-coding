# services/orchestrator/tests/test_escalation_routing_b4.py
"""B4: escalation routing to long-term channel + quick_reply_options payload."""
import json
import pytest
from tally_orchestrator.service import Db
from tally_orchestrator.channels import (
    insert_message, route_escalation_to_long_term_channel,
    get_workspace_escalation_channel_id,
)


def test_get_workspace_escalation_channel_id_defaults_to_general(db: Db):
    """Without settings_json config, resolves to the workspace's #general channel."""
    ch_id = get_workspace_escalation_channel_id(db, workspace_id=1)
    # Conftest creates a workspace with a #general channel.
    assert ch_id is not None
    row = db._conn.execute(
        "SELECT kind FROM channels WHERE id=?", (ch_id,)
    ).fetchone()
    assert row[0] == "general"


def test_get_workspace_escalation_channel_id_honors_settings(db: Db):
    """When workspaces.settings_json has escalation_channel_id, returns it."""
    # Create a custom channel, then set it as escalation target via settings_json
    ch_id = db._conn.execute(
        "INSERT INTO channels (workspace_id, kind, name, created_at) "
        "VALUES (1, 'custom', '#bugs', 1.0)"
    ).lastrowid
    db._conn.execute(
        "UPDATE workspaces SET settings_json=? WHERE id=1",
        (json.dumps({"escalation_channel_id": ch_id}),),
    )
    resolved = get_workspace_escalation_channel_id(db, workspace_id=1)
    assert resolved == ch_id


def test_route_escalation_to_long_term_channel_posts_structured_message(db: Db):
    """Escalation from a task channel creates a structured escalation card in #general."""
    task_id = db.create_task("Fix daily-deals", team_spec={}, user_id="admin")
    db.approve_task(task_id)
    task_ch = db._conn.execute(
        "SELECT id FROM channels WHERE task_id=? AND kind='task'", (task_id,)
    ).fetchone()[0]

    src_msg_id = insert_message(
        db, channel_id=task_ch, author_kind="agent", author_agent_id=0,
        kind="escalation",
        payload={
            "question": "Round to 2 decimals or keep 4?",
            "quick_reply_options": ["2 decimals", "Keep 4"],
            "need_user_input": True,
            "agent_name": "Coder",
            "agent_role": "Coder",
        },
    )

    result = route_escalation_to_long_term_channel(
        db, task_channel_id=task_ch, message_id=src_msg_id
    )
    assert result is not None
    lt_channel_id, new_msg_id = result

    row = db._conn.execute(
        "SELECT kind, payload_json, author_kind FROM messages WHERE id=?",
        (new_msg_id,),
    ).fetchone()
    assert row[2] == "tally"
    assert row[0] == "escalation"
    payload = json.loads(row[1])
    assert payload["quick_reply_options"] == ["2 decimals", "Keep 4"]
    assert payload["task_id"] == task_id
    assert "question" in payload
    assert "queue_position" in payload


def test_route_escalation_skips_non_escalation_message(db: Db):
    """A kind='text' message returns None — no routing performed."""
    task_id = db.create_task("Fix bug", team_spec={}, user_id="admin")
    db.approve_task(task_id)
    task_ch = db._conn.execute(
        "SELECT id FROM channels WHERE task_id=? AND kind='task'", (task_id,)
    ).fetchone()[0]
    msg_id = insert_message(
        db, channel_id=task_ch, author_kind="agent",
        kind="text", payload={"text": "all good"},
    )
    result = route_escalation_to_long_term_channel(
        db, task_channel_id=task_ch, message_id=msg_id
    )
    assert result is None
