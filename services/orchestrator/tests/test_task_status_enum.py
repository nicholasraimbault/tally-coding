"""Sprint 48: task status enum allows 'proposed' and 'cancelled'."""
from tally_orchestrator.service import Db, TASK_STATUS_TERMINAL, TASK_STATUS_COUNTS_AGAINST_QUOTA


def test_terminal_statuses_include_cancelled():
    assert "cancelled" in TASK_STATUS_TERMINAL
    assert "completed" in TASK_STATUS_TERMINAL
    assert "failed" in TASK_STATUS_TERMINAL


def test_proposed_is_not_terminal():
    """proposed is a pre-dispatch state — terminal=False."""
    assert "proposed" not in TASK_STATUS_TERMINAL


def test_proposed_does_not_count_against_quota(db: Db):
    """Status='proposed' tasks don't burn quota."""
    assert "proposed" not in TASK_STATUS_COUNTS_AGAINST_QUOTA


def test_cancelled_does_not_count_against_quota(db: Db):
    assert "cancelled" not in TASK_STATUS_COUNTS_AGAINST_QUOTA
