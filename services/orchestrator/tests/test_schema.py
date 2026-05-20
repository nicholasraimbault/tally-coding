"""Sprint 46: schema migration adds credit + push columns."""
from tally_orchestrator.service import Db


def test_quotas_new_columns_present(db: Db):
    cols = {row[1] for row in db._conn.execute("PRAGMA table_info(quotas)")}
    expected = {
        "per_task_cap_credits",
        "daily_spend_cap_credits",
        "weekly_spend_cap_credits",
        "overage_enabled",
        "auto_recharge_mode",
        "auto_recharge_block_credits",
        "auto_recharge_monthly_cap_micro_usd",
        "auto_recharge_spent_this_month_micro_usd",
        "stripe_payment_method_id",
        "prepaid_credit_balance",
        "spend_alert_threshold_pct",
        "alert_80_sent_at",
        "alert_100_sent_at",
    }
    assert expected.issubset(cols)


def test_new_tables_present(db: Db):
    names = {row[0] for row in db._conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table'"
    )}
    assert {"overage_purchases", "notification_rules", "notifications", "push_devices"}.issubset(names)


def test_migration_is_idempotent(tmp_db_path: str):
    """Re-opening the same DB shouldn't blow up on duplicate-column errors."""
    Db(tmp_db_path)
    Db(tmp_db_path)
    Db(tmp_db_path)  # third time still works
