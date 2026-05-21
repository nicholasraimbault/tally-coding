"""Sprint 49: persistent-agent cron polling loop."""
import asyncio
import time
import pytest
from tally_orchestrator.service import Db, Orchestrator


@pytest.mark.asyncio
async def test_persistent_agents_tick_fires_due_agent(db: Db, monkeypatch):
    """One tick of the loop dispatches a past-due agent + bumps next_scheduled_run_at."""
    pid = db.create_persistent_agent(
        workspace_id=1, name="a", role_name="Tester",
        team_spec={"nodes": [], "edges": []},
        cron_schedule="* * * * *",
    )
    # Force past-due
    db._conn.execute(
        "UPDATE persistent_agents SET next_scheduled_run_at=? WHERE id=?",
        (time.time() - 60, pid),
    )
    # Bypass __init__ to avoid worker pool setup
    orch = Orchestrator.__new__(Orchestrator)
    orch.db = db
    orch._stopping = False
    fired = []
    async def fake_fire(pid_, *, trigger):
        fired.append((pid_, trigger))
        return "fake-task-id"
    orch._fire_persistent_agent = fake_fire
    # Run ONE tick
    await orch._persistent_agents_tick()
    assert fired == [(pid, "cron")]
    # next_scheduled_run_at should have advanced
    new_next = db._conn.execute(
        "SELECT next_scheduled_run_at FROM persistent_agents WHERE id=?", (pid,)
    ).fetchone()[0]
    assert new_next > time.time()


@pytest.mark.asyncio
async def test_persistent_agents_tick_skips_disabled(db: Db):
    """Disabled agents aren't fired even if past-due."""
    pid = db.create_persistent_agent(
        workspace_id=1, name="a", role_name="Tester",
        team_spec={"nodes": [], "edges": []},
        cron_schedule="* * * * *",
    )
    db._conn.execute(
        "UPDATE persistent_agents SET enabled=0, next_scheduled_run_at=? WHERE id=?",
        (time.time() - 60, pid),
    )
    orch = Orchestrator.__new__(Orchestrator)
    orch.db = db
    orch._stopping = False
    fired = []
    async def fake_fire(pid_, *, trigger):
        fired.append(pid_)
        return None
    orch._fire_persistent_agent = fake_fire
    await orch._persistent_agents_tick()
    assert fired == []


@pytest.mark.asyncio
async def test_persistent_agents_tick_disables_invalid_cron(db: Db):
    """An invalid cron expression disables the agent + logs."""
    # create_persistent_agent validates cron at insert-time; inject an
    # invalid expression directly to simulate a row that was stored with
    # a bad schedule (e.g. migrated data or a future validation bypass).
    pid = db.create_persistent_agent(
        workspace_id=1, name="a", role_name="Tester",
        team_spec={"nodes": [], "edges": []},
        cron_schedule="* * * * *",
    )
    db._conn.execute(
        "UPDATE persistent_agents SET cron_schedule=?, next_scheduled_run_at=? WHERE id=?",
        ("not a cron", time.time() - 60, pid),
    )
    orch = Orchestrator.__new__(Orchestrator)
    orch.db = db
    orch._stopping = False
    async def fake_fire(pid_, *, trigger):
        return None
    orch._fire_persistent_agent = fake_fire
    await orch._persistent_agents_tick()
    enabled = db._conn.execute(
        "SELECT enabled FROM persistent_agents WHERE id=?", (pid,)
    ).fetchone()[0]
    assert enabled == 0
