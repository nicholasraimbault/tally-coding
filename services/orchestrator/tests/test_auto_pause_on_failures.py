"""Sprint 49: persistent agent auto-pauses after 3 consecutive failures."""
from tally_orchestrator.service import Db


def test_consecutive_failures_increments(db: Db):
    pid = db.create_persistent_agent(
        workspace_id=1, name="x", role_name="Tester", team_spec={},
    )
    db.bump_persistent_agent_failure(pid)
    assert db.get_persistent_agent(pid)["consecutive_failures"] == 1


def test_three_failures_disables_agent(db: Db):
    pid = db.create_persistent_agent(
        workspace_id=1, name="x", role_name="Tester", team_spec={},
    )
    for _ in range(3):
        db.bump_persistent_agent_failure(pid)
    assert db.get_persistent_agent(pid)["enabled"] is False


def test_three_failures_emits_permanent_failure_dm(db: Db):
    """After 3 failures, a templated 'permanent failure' DM is posted in the Tally↔owner DM."""
    pid = db.create_persistent_agent(
        workspace_id=1, name="my-agent", role_name="Tester", team_spec={},
    )
    for _ in range(3):
        db.bump_persistent_agent_failure(pid)
    # Find the DM channel between owner and Tally
    dm_row = db._conn.execute(
        "SELECT c.id FROM channels c "
        "JOIN channel_members cm1 ON cm1.channel_id=c.id "
        "JOIN channel_members cm2 ON cm2.channel_id=c.id "
        "WHERE c.kind='dm' AND cm1.member_kind='human' AND cm1.user_id='admin' "
        "AND cm2.member_kind='tally' "
        "LIMIT 1"
    ).fetchone()
    assert dm_row is not None
    msg_row = db._conn.execute(
        "SELECT payload_json FROM messages "
        "WHERE channel_id=? AND author_kind='tally' AND kind='text' "
        "ORDER BY id DESC LIMIT 1",
        (dm_row[0],),
    ).fetchone()
    assert msg_row is not None
    import json
    text = json.loads(msg_row[0]).get("text", "")
    assert "my-agent" in text
    assert "3 times" in text or "paused" in text


def test_success_resets_counter(db: Db):
    pid = db.create_persistent_agent(
        workspace_id=1, name="x", role_name="Tester", team_spec={},
    )
    db.bump_persistent_agent_failure(pid)
    db.bump_persistent_agent_failure(pid)
    db.reset_persistent_agent_failures(pid)
    assert db.get_persistent_agent(pid)["consecutive_failures"] == 0
