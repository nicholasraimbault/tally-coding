# services/orchestrator/tally_orchestrator/credits.py
"""Sprint 46: credit math.

Internal accounting unit: 1 credit = $0.01 of Red Pill COGS (10_000
micro_usd).  Used to express both included-credit allowances on plans
and per-task / period caps.

User-facing overage rate: $0.02/credit (2× COGS markup) across all
tiers.  Beta plans bake in a 1.5× markup on the included credits
(stable plans will be 2×).  Both knobs above live here as constants
so price tuning is a one-liner deploy.
"""
from __future__ import annotations

# 1 credit costs us $0.01 of Red Pill inference.
COGS_MICRO_USD_PER_CREDIT = 10_000

# Sold to users at 2× markup for one-time + auto-recharge purchases.
OVERAGE_CREDIT_PRICE_MICRO_USD = 20_000

# Stripe charges $0.30 + 2.9% fixed fee; below ~$5 the fee eats the margin.
MIN_PURCHASE_CREDITS = 250  # $5.00 minimum one-time purchase


def micro_usd_to_credits(micro_usd: int) -> int:
    """Convert a `cost_events.cost_micro_usd` value to credits.

    Rounds **up** so partial-cent usage always counts as a full
    credit (never undercount spend; the alternative bankrupts us on
    high-volume low-cost calls)."""
    if micro_usd <= 0:
        return 0
    return (micro_usd + COGS_MICRO_USD_PER_CREDIT - 1) // COGS_MICRO_USD_PER_CREDIT


def credits_to_micro_usd(credits: int) -> int:
    """Convert credits → micro_usd at the user-facing overage rate.

    Used to compute Stripe charge amounts when the user buys credits
    or when auto-recharge fires."""
    if credits <= 0:
        return 0
    return credits * OVERAGE_CREDIT_PRICE_MICRO_USD
