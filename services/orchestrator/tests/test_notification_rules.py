# services/orchestrator/tests/test_notification_rules.py
"""Sprint 46: notification rule evaluation."""
import json
import time
from tally_orchestrator.notifications import (
    evaluate_rules_for_cost_event,
    seed_default_rules,
    insert_notification,
    list_notifications,
)


def test_seed_default_rules_creates_80_and_100(db):
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    seed_default_rules(db, "u1", plan="pro_beta")
    rows = db._conn.execute(
        "SELECT kind, threshold FROM notification_rules WHERE user_id='u1' ORDER BY threshold"
    ).fetchall()
    assert ("period_pct", 80) in [tuple(r) for r in rows]
    assert ("period_pct", 100) in [tuple(r) for r in rows]


def test_seed_skips_mode_3(db):
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    db._conn.execute("UPDATE quotas SET auto_recharge_mode=3 WHERE user_id='u1'")
    seed_default_rules(db, "u1", plan="pro_beta")
    rows = db._conn.execute(
        "SELECT COUNT(*) FROM notification_rules WHERE user_id='u1'"
    ).fetchone()
    assert rows[0] == 0  # Mode 3 users get nothing seeded


def test_evaluate_fires_period_pct_when_crossed(db):
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    seed_default_rules(db, "u1", plan="pro_beta")
    # Push 80% of 1000 = 800 credits into cost_events
    db.record_cost_event(
        user_id="u1", kind="worker", model="meta-llama/llama-3.3-70b-instruct",
        prompt_tokens=0, completion_tokens=0, total_tokens=0,
        cost_micro_usd=8_000_000,
    )
    fired = evaluate_rules_for_cost_event(db, "u1")
    kinds = [n["kind"] for n in fired]
    assert "period_pct_crossed" in kinds


def test_evaluate_fires_period_pct_only_once(db):
    """Re-evaluating after first fire shouldn't refire the same rule."""
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    seed_default_rules(db, "u1", plan="pro_beta")
    db.record_cost_event(
        user_id="u1", kind="worker", model="meta-llama/llama-3.3-70b-instruct",
        prompt_tokens=0, completion_tokens=0, total_tokens=0,
        cost_micro_usd=8_000_000,
    )
    first = evaluate_rules_for_cost_event(db, "u1")
    assert len(first) > 0
    second = evaluate_rules_for_cost_event(db, "u1")
    assert second == []


def test_daily_amount_refires_after_24h(db):
    """Daily rules should reset every 24h, not at billing period start."""
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    db._conn.execute(
        "INSERT INTO notification_rules (user_id, kind, threshold, enabled, created_at) "
        "VALUES ('u1', 'daily_amount', 10, 1, ?)",
        (time.time() - 100,),
    )
    # Push 20 credits of usage
    db.record_cost_event(
        user_id="u1", kind="worker", model="meta-llama/llama-3.3-70b-instruct",
        prompt_tokens=0, completion_tokens=0, total_tokens=0,
        cost_micro_usd=200_000,
    )
    first = evaluate_rules_for_cost_event(db, "u1")
    assert any(n["kind"] == "daily_amount_reached" for n in first)
    # Re-evaluate immediately → no re-fire (still within 24h)
    second = evaluate_rules_for_cost_event(db, "u1")
    assert second == []
    # Force last_fired_at backward by 25h → rule should be eligible to refire
    db._conn.execute(
        "UPDATE notification_rules SET last_fired_at=? WHERE user_id='u1' AND kind='daily_amount'",
        (time.time() - 25 * 3600,),
    )
    third = evaluate_rules_for_cost_event(db, "u1")
    assert any(n["kind"] == "daily_amount_reached" for n in third)


def test_insert_notification_and_list(db):
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    nid = insert_notification(db, "u1", kind="test", severity="info", payload={"k": "v"})
    out = list_notifications(db, "u1", limit=10)
    assert len(out) == 1
    assert out[0]["id"] == nid
    assert json.loads(out[0]["payload_json"]) == {"k": "v"}
