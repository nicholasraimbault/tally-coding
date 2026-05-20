"""Sprint 46: credit balance / period usage / prepaid Db methods."""
from tally_orchestrator.service import Db


def test_credits_used_this_period_zero_when_no_events(db: Db):
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    start = db.get_or_create_quota("u1")["period_start"]
    assert db.credits_used_this_period("u1", start) == 0


def test_credits_used_this_period_sums_cost_events(db: Db):
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    start = db.get_or_create_quota("u1")["period_start"]
    # 3 events of 50_000 micro_usd = 5 credits each = 15 credits total
    for _ in range(3):
        db.record_cost_event(
            user_id="u1", kind="architect", model="meta-llama/llama-3.3-70b-instruct",
            prompt_tokens=100, completion_tokens=200, total_tokens=300,
            cost_micro_usd=50_000,
        )
    assert db.credits_used_this_period("u1", start) == 15


def test_credits_available_subtracts_used_adds_prepaid(db: Db):
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    # 100 credits used, 500 prepaid
    db.record_cost_event(
        user_id="u1", kind="architect", model="meta-llama/llama-3.3-70b-instruct",
        prompt_tokens=0, completion_tokens=0, total_tokens=0,
        cost_micro_usd=1_000_000,  # 100 credits
    )
    db.set_prepaid_balance("u1", 500)
    avail = db.credits_available("u1")
    assert avail == 1000 - 100 + 500  # 1400


def test_set_prepaid_balance_idempotent(db: Db):
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    db.set_prepaid_balance("u1", 250)
    db.set_prepaid_balance("u1", 250)
    assert db.get_prepaid_balance("u1") == 250


def test_increment_prepaid_balance_adds(db: Db):
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    db.increment_prepaid_balance("u1", 100)
    db.increment_prepaid_balance("u1", 150)
    assert db.get_prepaid_balance("u1") == 250


def test_consume_prepaid_balance_floors_at_zero(db: Db):
    """Spending more credits than the prepaid balance clamps to 0, never negative."""
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    db.set_prepaid_balance("u1", 100)
    db.consume_prepaid_balance("u1", 250)  # over-consume
    assert db.get_prepaid_balance("u1") == 0


def test_effective_per_task_cap_credits_uses_quota_override(db: Db):
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    # No override → falls back to plan default (100 for pro_beta)
    assert db.effective_per_task_cap_credits("u1") == 100
    db.set_per_task_cap("u1", 50)
    assert db.effective_per_task_cap_credits("u1") == 50
