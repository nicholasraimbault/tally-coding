"""Sprint 46: per-team cost estimate (Checkpoint 4)."""
from tally_orchestrator.cost_estimate import estimate_team_cost_credits


def test_estimate_returns_per_agent_breakdown():
    team_spec = {
        "agents": [
            {"role": "Coder", "model": "moonshotai/kimi-k2.6-instruct"},
            {"role": "Reviewer", "model": "moonshotai/kimi-k2.6-instruct"},
        ],
    }
    out = estimate_team_cost_credits(team_spec, description_length=200)
    assert "total_credits" in out
    assert "per_agent" in out
    assert len(out["per_agent"]) == 2
    assert out["total_credits"] == sum(p["credits"] for p in out["per_agent"])


def test_estimate_zero_for_empty_team():
    assert estimate_team_cost_credits({"agents": []}, description_length=0) == {
        "total_credits": 0,
        "per_agent": [],
    }


def test_estimate_uses_premium_model_higher():
    cheap_team = {"agents": [{"role": "X", "model": "meta-llama/llama-3.3-70b-instruct"}]}
    expensive_team = {"agents": [{"role": "X", "model": "moonshotai/kimi-k2.6-instruct"}]}
    cheap = estimate_team_cost_credits(cheap_team, description_length=500)["total_credits"]
    expensive = estimate_team_cost_credits(expensive_team, description_length=500)["total_credits"]
    assert expensive > cheap
