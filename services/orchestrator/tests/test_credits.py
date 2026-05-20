"""Sprint 46: credit math + plan config."""
from tally_orchestrator.service import QUOTA_PLANS


def test_beta_tiers_present():
    assert {"free", "pro_beta", "max_beta", "ultra_beta", "unlimited"}.issubset(QUOTA_PLANS.keys())


def test_pro_beta_priced_at_15():
    plan = QUOTA_PLANS["pro_beta"]
    assert plan["price_micro_usd_monthly"] == 15_000_000
    assert plan["included_credits"] == 1000
    assert plan["default_per_task_cap_credits"] == 100
    assert plan["model_allowlist"] is None
    assert plan["overage_eligible"] is True
    assert plan["is_beta"] is True


def test_max_beta_priced_at_75():
    plan = QUOTA_PLANS["max_beta"]
    assert plan["price_micro_usd_monthly"] == 75_000_000
    assert plan["included_credits"] == 5000
    assert plan["default_per_task_cap_credits"] == 500


def test_ultra_beta_priced_at_150():
    plan = QUOTA_PLANS["ultra_beta"]
    assert plan["price_micro_usd_monthly"] == 150_000_000
    assert plan["included_credits"] == 10_000
    assert plan["default_per_task_cap_credits"] == 1000


def test_free_tier_restricts_to_llama():
    plan = QUOTA_PLANS["free"]
    assert plan["included_credits"] == 50
    assert plan["default_per_task_cap_credits"] == 25
    assert plan["max_per_task_cap_credits"] == 50
    assert plan["model_allowlist"] == {"meta-llama/llama-3.3-70b-instruct"}
    assert plan["overage_eligible"] is False


def test_unlimited_bypasses_caps():
    plan = QUOTA_PLANS["unlimited"]
    assert plan["included_credits"] >= 10**8
