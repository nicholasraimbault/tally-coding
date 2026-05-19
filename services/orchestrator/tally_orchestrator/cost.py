"""Sprint 39: LLM cost accounting.

Captures token usage from Red Pill responses, computes a USD cost
using a static price table, and exposes per-user / per-task /
per-period aggregations to the Flutter Billing screen.

Why a static price table?  Red Pill bills the orchestrator (not the
end-user); we recompute "what would this have cost?" so users can
see the spend their tasks generate.  Prices drift — a periodic sync
against `https://api.redpill.ai/v1/models` could automate this; for
now, manual updates on a per-quarter cadence are good enough.

All prices in **USD per million tokens** (separate prompt and
completion).  Multiply by token count and divide by 1_000_000 to
get USD; we store the result as ``cost_micro_usd`` (integer
micro-dollars: 1 USD = 1_000_000) so SQLite rows don't accumulate
float-rounding drift over time.

Models we know about:
"""
from __future__ import annotations

import logging

logger = logging.getLogger("tally.cost")


# Pricing snapshot 2026-05.  Source: Red Pill provider pricing page +
# upstream model docs.  Best-effort estimates — variance ±20% is fine
# for "is the user about to blow their plan" decisions.
#
# Format: model_id → (prompt_per_million_usd, completion_per_million_usd)
PRICE_TABLE: dict[str, tuple[float, float]] = {
    # Llama 3.3 70B — fast architect-grade model.
    "meta-llama/llama-3.3-70b-instruct": (0.59, 0.79),
    # Kimi K2 / K2.6 — strong coding model, more expensive output.
    "moonshotai/kimi-k2-instruct": (0.60, 2.50),
    "moonshotai/kimi-k2.6-instruct": (0.60, 2.50),
    # DeepSeek R1 — reasoning model; high completion cost.
    "deepseek/deepseek-r1-0528": (0.55, 2.19),
    "deepseek/deepseek-r1": (0.55, 2.19),
    # DeepSeek V3.2 — cheaper general-purpose.
    "deepseek/deepseek-v3.2": (0.27, 1.10),
    "deepseek/deepseek-v3": (0.27, 1.10),
}

# Fallback when the architect / agent uses a model we don't know
# about.  Picks the Llama 3.3 70B price as a conservative midpoint —
# usage shows up in dashboards but doesn't wildly under- or over-bill.
_FALLBACK_PRICES = (0.59, 0.79)


def compute_cost_micro_usd(
    model: str, prompt_tokens: int, completion_tokens: int
) -> int:
    """Convert ``(model, prompt_tokens, completion_tokens)`` to an
    integer micro-dollar cost.  1 USD = 1_000_000 micro_usd.

    Returns 0 when tokens are 0/negative.  Logs a one-line warning the
    first time we see an unknown model so operators know to add it
    to the table.
    """
    if prompt_tokens <= 0 and completion_tokens <= 0:
        return 0
    prices = PRICE_TABLE.get(model)
    if prices is None:
        logger.warning(
            "cost: unknown model %r; using fallback prices (%.2f/%.2f $/M tokens)",
            model, *_FALLBACK_PRICES,
        )
        prices = _FALLBACK_PRICES
    prompt_cost_usd = max(0, prompt_tokens) * prices[0] / 1_000_000
    completion_cost_usd = max(0, completion_tokens) * prices[1] / 1_000_000
    total_usd = prompt_cost_usd + completion_cost_usd
    return int(round(total_usd * 1_000_000))


def format_micro_usd(micro_usd: int) -> str:
    """Human-readable string for log lines.  $0.001234 → "$0.0012"
    for tiny amounts, "$1.23" otherwise."""
    usd = micro_usd / 1_000_000
    if usd < 0.01:
        return f"${usd:.4f}"
    return f"${usd:.2f}"
