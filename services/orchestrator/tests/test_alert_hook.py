# services/orchestrator/tests/test_alert_hook.py
"""Sprint 46: Checkpoint 7 — alert evaluation fires after cost events."""
import pytest


async def test_emit_notification_fires_when_threshold_crossed(db):
    """80% threshold should fire after enough usage."""
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    from tally_orchestrator.notifications import seed_default_rules, evaluate_rules_for_cost_event
    seed_default_rules(db, "u1", plan="pro_beta")
    # 80% of 1000 = 800
    db.record_cost_event(
        user_id="u1", kind="worker", model="meta-llama/llama-3.3-70b-instruct",
        prompt_tokens=0, completion_tokens=0, total_tokens=0,
        cost_micro_usd=8_000_000,
    )
    fired = evaluate_rules_for_cost_event(db, "u1")
    assert any(n["kind"] == "period_pct_crossed" for n in fired)
