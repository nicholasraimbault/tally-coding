# services/orchestrator/tests/test_push_escalation_payload.py
"""B4: escalation push payload encoding."""
import asyncio
import json
import time
import pytest
from tally_orchestrator.service import Db
from tally_orchestrator.notifications import emit_escalation_push


@pytest.mark.asyncio
async def test_emit_escalation_push_posts_to_unifiedpush_endpoint(db: Db):
    """Push notification body contains the escalation payload (not empty doorbell)."""
    # Register a fake UnifiedPush device
    db._conn.execute(
        "INSERT INTO push_devices (user_id, provider, endpoint_url, enabled, created_at) "
        "VALUES ('admin', 'unifiedpush', 'http://localhost:19999/fake', 1, ?)",
        (time.time(),),
    )

    from unittest.mock import AsyncMock, patch, MagicMock

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    mock_client.post = AsyncMock()

    captured = []

    async def capture_post(url, *, content):
        captured.append(content)

    mock_client.post.side_effect = capture_post

    with patch("tally_orchestrator.notifications.httpx.AsyncClient", return_value=mock_client):
        await emit_escalation_push(
            db,
            user_id="admin",
            escalation_message_id=42,
            channel_id=7,
            payload={
                "question": "Round to 2 or 4 decimals?",
                "quick_reply_options": ["2 decimals", "Keep 4"],
                "task_id": "abc123",
            },
        )

    assert len(captured) == 1
    body = json.loads(captured[0])
    assert body["escalation_message_id"] == 42
    assert body["channel_id"] == 7
    assert body["quick_reply_options"] == ["2 decimals", "Keep 4", "Open"]


@pytest.mark.asyncio
async def test_emit_escalation_push_includes_open_action(db: Db):
    """'Open' is always appended as the last quick reply option."""
    db._conn.execute(
        "INSERT INTO push_devices (user_id, provider, endpoint_url, enabled, created_at) "
        "VALUES ('admin', 'unifiedpush', 'http://localhost:19999/fake', 1, ?)",
        (time.time(),),
    )

    from unittest.mock import AsyncMock, patch, MagicMock

    mock_client = MagicMock()
    mock_client.__aenter__ = AsyncMock(return_value=mock_client)
    mock_client.__aexit__ = AsyncMock(return_value=None)
    captured = []

    async def capture_post(url, *, content):
        captured.append(content)

    mock_client.post = AsyncMock(side_effect=capture_post)

    with patch("tally_orchestrator.notifications.httpx.AsyncClient", return_value=mock_client):
        await emit_escalation_push(
            db,
            user_id="admin",
            escalation_message_id=1,
            channel_id=1,
            payload={"question": "Fix?", "quick_reply_options": ["Yes", "No"]},
        )

    body = json.loads(captured[0])
    assert body["quick_reply_options"][-1] == "Open"
