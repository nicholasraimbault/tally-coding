"""Sprint 48: team_proposal messages."""
import json
from tally_orchestrator.service import Db
from tally_orchestrator.channels import insert_team_proposal_message


def test_insert_team_proposal_message(db: Db):
    """Inserts a kind='team_proposal' message in the user's #general channel."""
    task_id = db.create_task("build a sorter", team_spec={"agents": [{"role": "Coder"}]}, user_id="admin")
    msg_id = insert_team_proposal_message(
        db,
        task_id=task_id,
        user_id="admin",
        description="build a sorter",
        team_spec={"nodes": [{"id": "n1", "kind": "agent", "role": "Coder"}], "edges": [], "format": "nodes_v1"},
    )
    assert msg_id > 0
    row = db._conn.execute(
        "SELECT kind, payload_json, author_kind FROM messages WHERE id=?", (msg_id,)
    ).fetchone()
    assert row[0] == "team_proposal"
    assert row[2] == "tally"
    payload = json.loads(row[1])
    assert payload["task_id"] == task_id
    assert payload["description"] == "build a sorter"
    assert payload["team_spec"]["nodes"][0]["role"] == "Coder"
    assert {opt["value"] for opt in payload["options"]} == {"approve", "edit", "cancel"}


def test_insert_team_proposal_message_no_general_channel_returns_zero(db: Db):
    """If the user has no #general channel, returns 0."""
    msg_id = insert_team_proposal_message(
        db, task_id="t", user_id="ghost-user-with-no-workspace", description="x", team_spec={},
    )
    assert msg_id == 0
