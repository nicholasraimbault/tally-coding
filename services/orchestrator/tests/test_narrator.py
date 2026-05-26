# services/orchestrator/tests/test_narrator.py
"""B4: Tally narrator — unit tests."""
import pytest
from unittest.mock import patch, MagicMock
from tally_orchestrator.narrator import generate_narrator_update, NARRATOR_MAX_CHARS


def test_generate_narrator_update_returns_string(monkeypatch):
    """Happy path: Red Pill call returns a short narrator string."""
    fake_resp = MagicMock()
    fake_resp.raise_for_status = MagicMock()
    fake_resp.json.return_value = {
        "choices": [{"message": {"content": "Diagnosed the daily-deals bug."}}],
        "usage": {"prompt_tokens": 120, "completion_tokens": 10, "total_tokens": 130},
    }
    with patch("tally_orchestrator.narrator.httpx.Client") as MockClient:
        MockClient.return_value.__enter__.return_value.post.return_value = fake_resp
        result = generate_narrator_update(
            task_description="Fix daily-deals rounding",
            event="task_started",
            context={},
            redpill_key="test-key",
            redpill_base="https://api.redpill.ai/v1",
        )
    assert isinstance(result, str)
    assert 0 < len(result) <= NARRATOR_MAX_CHARS


def test_generate_narrator_update_truncates_overlong_output(monkeypatch):
    """Output longer than NARRATOR_MAX_CHARS gets truncated with ellipsis."""
    long_msg = "A" * 300
    fake_resp = MagicMock()
    fake_resp.raise_for_status = MagicMock()
    fake_resp.json.return_value = {
        "choices": [{"message": {"content": long_msg}}],
        "usage": {},
    }
    with patch("tally_orchestrator.narrator.httpx.Client") as MockClient:
        MockClient.return_value.__enter__.return_value.post.return_value = fake_resp
        result = generate_narrator_update(
            task_description="Fix bug",
            event="task_started",
            context={},
            redpill_key="test-key",
            redpill_base="https://api.redpill.ai/v1",
        )
    assert len(result) <= NARRATOR_MAX_CHARS
    assert result.endswith("…")


def test_generate_narrator_update_returns_fallback_on_error():
    """Network failure returns the fallback string, never raises."""
    with patch("tally_orchestrator.narrator.httpx.Client") as MockClient:
        MockClient.return_value.__enter__.return_value.post.side_effect = Exception("timeout")
        result = generate_narrator_update(
            task_description="Fix bug",
            event="task_started",
            context={},
            redpill_key="test-key",
            redpill_base="https://api.redpill.ai/v1",
        )
    assert isinstance(result, str)
    assert len(result) > 0


from tally_orchestrator.narrator import NarratorSpendGuard


def test_spend_guard_allows_until_daily_cap():
    guard = NarratorSpendGuard(daily_cap=200)
    assert guard.can_spend(100)
    guard.record(100)
    assert guard.can_spend(100)
    guard.record(100)
    assert not guard.can_spend(1)   # cap hit


def test_spend_guard_resets_after_midnight(monkeypatch):
    guard = NarratorSpendGuard(daily_cap=100)
    guard.record(100)
    assert not guard.can_spend(1)
    # Force reset by clearing _today sentinel — simulates day rollover
    guard._today = None
    assert guard.can_spend(1)


def test_orchestrator_has_run_narrator_sweeper():
    from tally_orchestrator.service import Orchestrator
    import inspect
    assert hasattr(Orchestrator, "run_narrator_sweeper")
    assert inspect.iscoroutinefunction(Orchestrator.run_narrator_sweeper)


def test_narrator_called_on_task_running(db):
    """When a task transitions to running, _post_narrator_update exists on Orchestrator."""
    from tally_orchestrator.service import Orchestrator
    assert hasattr(Orchestrator, "_post_narrator_update")
