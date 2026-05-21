"""Sprint 49: agent escalation -> Tally DM to workspace owner."""
import json
from tally_orchestrator.service import Db
from tally_orchestrator.channels import (
    insert_message, ensure_dm_channel, handle_escalation,
)


def test_ensure_dm_channel_creates_idempotent(db: Db):
    """First call creates; second call returns the same channel_id."""
    ch1 = ensure_dm_channel(db, workspace_id=1, kind_a="human", id_a="admin", kind_b="tally", id_b=None)
    ch2 = ensure_dm_channel(db, workspace_id=1, kind_a="human", id_a="admin", kind_b="tally", id_b=None)
    assert ch1 == ch2 and ch1 > 0


def test_ensure_dm_channel_has_both_members(db: Db):
    ch = ensure_dm_channel(db, workspace_id=1, kind_a="human", id_a="admin", kind_b="tally", id_b=None)
    rows = db._conn.execute(
        "SELECT member_kind, user_id FROM channel_members WHERE channel_id=?", (ch,)
    ).fetchall()
    kinds = {r[0] for r in rows}
    assert {"human", "tally"}.issubset(kinds)


def test_handle_escalation_creates_dm_with_templated_message(db: Db):
    """A kind='escalation' message in a scheduled_agent channel triggers
    a Tally DM with the templated content."""
    pid = db.create_persistent_agent(
        workspace_id=1, name="nightly-tests", role_name="Tester", team_spec={},
    )
    sa_ch = db._conn.execute(
        "SELECT id FROM channels WHERE persistent_agent_id=?", (pid,)
    ).fetchone()[0]
    msg_id = insert_message(
        db, channel_id=sa_ch, author_kind="agent", author_agent_id=0,
        kind="escalation",
        payload={
            "reason": "Test suite is failing intermittently",
            "agent_name": "nightly-tests",
            "agent_role": "Tester",
        },
    )
    dm_ch_id = handle_escalation(db, channel_id=sa_ch, message_id=msg_id)
    assert dm_ch_id is not None
    # Verify a Tally text message was inserted in the DM channel
    row = db._conn.execute(
        "SELECT kind, payload_json, author_kind FROM messages "
        "WHERE channel_id=? AND kind='text' ORDER BY id DESC LIMIT 1",
        (dm_ch_id,),
    ).fetchone()
    assert row is not None
    assert row[2] == "tally"
    text = json.loads(row[1]).get("text", "")
    assert "nightly-tests" in text
    assert "intermittently" in text
