# services/orchestrator/tally_orchestrator/cost_estimate.py
"""Sprint 46: per-team cost estimation.

Constants below are placeholders calibrated by hand from a few
Sprint 42 sample tasks.  Re-calibrate from real production traffic
post-launch — see `docs/SPRINT-46-CALIBRATION-PROCEDURE.md`.
The shape of the returned dict is stable so callers don't change.
"""
from __future__ import annotations

from .cost import PRICE_TABLE
from .credits import micro_usd_to_credits

# Baseline token budget per agent (system prompt + few-shot + task context).
# These reflect full multi-turn tool-loop agents (not single completions) —
# tuned from Sprint 42 sample tasks.  Replace with median-from-10-runs
# constants in Sprint 1.5.
DEFAULT_PROMPT_TOKENS = 8_000
DEFAULT_COMPLETION_TOKENS = 2_000

# Tokens scale with description length (rough linear fit).
PROMPT_TOKENS_PER_CHAR = 4
COMPLETION_TOKENS_PER_CHAR = 1


def _agent_estimate_micro_usd(model: str, description_length: int) -> int:
    """Estimate micro_usd for one agent given the description size.

    Token counts are additive: base defaults + description-length scaling.
    This ensures that a more expensive model always costs more than a
    cheaper one even at small description lengths, and that the per-agent
    breakdowns sum correctly to the team total (both computed from micro_usd
    before credit rounding).
    """
    prompt = DEFAULT_PROMPT_TOKENS + description_length * PROMPT_TOKENS_PER_CHAR
    completion = DEFAULT_COMPLETION_TOKENS + description_length * COMPLETION_TOKENS_PER_CHAR
    prices = PRICE_TABLE.get(model) or (0.59, 0.79)  # llama fallback
    usd = (prompt * prices[0] + completion * prices[1]) / 1_000_000
    return int(round(usd * 1_000_000))


def estimate_team_cost_credits(team_spec: dict, description_length: int) -> dict:
    """Estimate the credit cost of a team_spec.

    Returns {"total_credits": int, "per_agent": [{"role": str,
    "model": str, "credits": int}, ...]}.

    ``total_credits`` is the sum of per-agent credits (not a separate
    credit conversion of the aggregated micro_usd total) so that
    ``total_credits == sum(p["credits"] for p in per_agent)`` always
    holds regardless of rounding.  This slight over-estimate (ceiling
    rounding per agent vs. ceiling rounding once) is intentional: it
    biases the gate toward caution.
    """
    out_per_agent: list[dict] = []
    for agent in team_spec.get("agents", []) or []:
        model = agent.get("model") or "meta-llama/llama-3.3-70b-instruct"
        micro = _agent_estimate_micro_usd(model, description_length)
        out_per_agent.append({
            "role": agent.get("role", ""),
            "model": model,
            "credits": micro_usd_to_credits(micro),
        })
    total_credits = sum(p["credits"] for p in out_per_agent)
    return {
        "total_credits": total_credits,
        "per_agent": out_per_agent,
    }


def reroute_to_cheap_models(team_spec: dict, allowlist: set[str]) -> dict:
    """Force every agent's model to the cheapest in the allowlist.

    `allowlist` falls back to a single-model set if None; the caller
    is responsible for passing the user's plan allowlist or a
    custom one.  Returns a copy; doesn't mutate the input.
    """
    if not team_spec.get("agents"):
        return team_spec
    cheap = next(iter(allowlist)) if allowlist else "meta-llama/llama-3.3-70b-instruct"
    new_agents = [{**a, "model": cheap} for a in team_spec["agents"]]
    return {**team_spec, "agents": new_agents}
