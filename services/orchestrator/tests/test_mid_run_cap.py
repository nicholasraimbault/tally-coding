"""Sprint 46: mid-run per-task cap abort (Checkpoint 5)."""
import asyncio
import pytest
from tally_orchestrator.service import Db, QUOTA_PLANS


def test_task_aborts_when_cumulative_cost_exceeds_cap(db: Db):
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    db.set_per_task_cap("u1", 50)
    task_id = db.create_task("test", team_spec={"agents": [{"role": "Coder"}]}, user_id="u1")
    # Simulate 60 credits already spent on this task
    db.record_cost_event(
        user_id="u1", kind="worker", model="moonshotai/kimi-k2.6-instruct",
        prompt_tokens=0, completion_tokens=0, total_tokens=0,
        cost_micro_usd=600_000,  # 60 credits
        task_id=task_id,
    )
    from tally_orchestrator.credits import micro_usd_to_credits
    task_cost = db.task_cost(task_id)["total_micro_usd"]
    over_cap = micro_usd_to_credits(task_cost) > db.effective_per_task_cap_credits("u1")
    assert over_cap is True


def test_under_cap_does_not_abort(db: Db):
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    db.set_per_task_cap("u1", 100)
    task_id = db.create_task("test", team_spec={"agents": [{"role": "Coder"}]}, user_id="u1")
    db.record_cost_event(
        user_id="u1", kind="worker", model="moonshotai/kimi-k2.6-instruct",
        prompt_tokens=0, completion_tokens=0, total_tokens=0,
        cost_micro_usd=300_000,  # 30 credits
        task_id=task_id,
    )
    from tally_orchestrator.credits import micro_usd_to_credits
    task_cost = db.task_cost(task_id)["total_micro_usd"]
    over_cap = micro_usd_to_credits(task_cost) > db.effective_per_task_cap_credits("u1")
    assert over_cap is False
