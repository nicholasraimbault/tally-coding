# Sprint 46 — Credit-Based Pricing & Privacy-Respecting Push Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace flat task-count tiers with credit-based pricing denominated in dollars-of-COGS, enforced via per-task + period caps, and ship privacy-respecting push notifications (UnifiedPush + WebSocket + desktop native) so beta users can use Tally Coding on Android (F-Droid + GitHub APK) and Linux without leaking notification content through FCM/APNs.

**Architecture:** Three coupled phases — (A) orchestrator backend adds credit accounting, seven enforcement checkpoints, direct-Stripe Checkout/auto-recharge, notification rules, doorbell-style push fan-out, and a /ws/notifications WebSocket; (B) Flutter app gets billing screen overhaul, composer cost estimate, task ticker, cap-abort dialog, notifications screen, UnifiedPush registration, desktop libnotify, and a foreground WebSocket; (C) public Astro/Starlight docs-site with the beta pricing page, sample-task calibration, build & deploy to Phala CVM.

**Tech Stack:** Python 3.12 (FastAPI, sqlite3, httpx, stripe-python, websockets), Flutter 3.6+ (Dart, http, web_socket_channel, unifiedpush_android, flutter_local_notifications), Astro + Starlight (docs-site). Single Phala TDX CVM image `tally-orch:v26` deploys the orchestrator.

---

## Scope check

This spec is one sprint targeting tightly-coupled subsystems (frontend needs backend; notifications cross both; docs-site is standalone). One plan with three internal phases is the right shape; each phase produces a working deliverable on its own (backend testable via curl, Flutter testable against deployed backend, docs-site is fully independent).

## Pre-implementation gate

**Before Task A1:** Verify Clerk dashboard exposes a Stripe restricted key with scopes `charges:write`, `payment_intents:write`, `checkout_sessions:write`, `customers:read`, `payment_methods:read`. If unavailable, fall back to Clerk Billing's metered subscription items API (worse UX but no separate Stripe access needed). Spec section "Stripe access path" lists both paths. Resolution recorded as a one-liner at the top of `services/orchestrator/tally_orchestrator/stripe_direct.py` (see Task A11).

## File structure

### Files to create

```
services/orchestrator/tally_orchestrator/credits.py        ~150 lines  Credit math, plan reads
services/orchestrator/tally_orchestrator/stripe_direct.py  ~250 lines  Checkout, off-session PaymentIntent, idempotency
services/orchestrator/tally_orchestrator/notifications.py  ~250 lines  Push fan-out, rule eval, UnifiedPush HTTP, jitter
services/orchestrator/tests/__init__.py                    empty
services/orchestrator/tests/conftest.py                    ~60 lines   pytest fixtures (tmp db, mocked stripe, mocked httpx)
services/orchestrator/tests/test_credits.py                ~120 lines  Credit math + plan reads
services/orchestrator/tests/test_credit_gates.py           ~100 lines  POST /tasks gates
services/orchestrator/tests/test_mid_run_cap.py            ~100 lines  Mid-run abort
services/orchestrator/tests/test_stripe_direct.py          ~150 lines  Mocked stripe-python
services/orchestrator/tests/test_stripe_webhook.py         ~120 lines  Webhook signature + handler
services/orchestrator/tests/test_notification_rules.py     ~100 lines  Rule eval
services/orchestrator/tests/test_unifiedpush_delivery.py    ~80 lines  HTTP POST shape + jitter

tally_coding_app/lib/screens/notifications_screen.dart     ~400 lines  Devices + rules + inbox
tally_coding_app/lib/widgets/credit_balance_widget.dart    ~100 lines  Progress + subscription/prepaid split
tally_coding_app/lib/widgets/cost_estimate_banner.dart     ~120 lines  Composer banner
tally_coding_app/lib/widgets/task_cost_ticker.dart         ~100 lines  Task channel chip
tally_coding_app/lib/widgets/cap_abort_dialog.dart         ~100 lines  Modal
tally_coding_app/lib/services/unified_push.dart            ~100 lines  Android UnifiedPush wrapper
tally_coding_app/lib/services/desktop_notifier.dart        ~80 lines   Linux libnotify wrapper
tally_coding_app/lib/services/notifications_ws.dart        ~150 lines  WS client + reconnect

docs-site/package.json                                     scaffold
docs-site/astro.config.mjs                                 scaffold
docs-site/src/content/docs/index.mdx                       hero
docs-site/src/content/docs/pricing.mdx                     pricing table + FAQ

docs/SPRINT-46-COMPLETE.md                                 sprint completion log
```

### Files to modify

```
services/orchestrator/tally_orchestrator/service.py        SCHEMA, QUOTA_PLANS, DB methods, ~15 new routes, POST /tasks gate, _on_agent_complete hooks
services/orchestrator/tally_orchestrator/architect.py      Accept model_allowlist parameter
services/orchestrator/pyproject.toml                       Add stripe, websockets deps
services/orchestrator/Dockerfile                           Bump version label to v26 (if explicit)

tally_coding_app/pubspec.yaml                              Add web_socket_channel, unifiedpush_android, flutter_local_notifications
tally_coding_app/lib/api.dart                              ~15 new methods (credits, billing, notifications, push, ws)
tally_coding_app/lib/main.dart                             Wire notifications screen + WS lifecycle
tally_coding_app/lib/screens/discord_shell.dart            Notifications rail icon w/ unread badge
tally_coding_app/lib/screens/billing_screen.dart           Full overhaul
tally_coding_app/lib/screens/general_channel.dart          Cost estimate banner above composer
tally_coding_app/lib/screens/task_channel.dart             Cost ticker chip + cap-abort dialog hook
tally_coding_app/android/app/src/main/AndroidManifest.xml  UnifiedPush receiver
tally_coding_app/linux/CMakeLists.txt                      Link libnotify (if not already)
```

### Worker repo (tally-workers)

```
~/Projects/pronoic/tally-workers/...                       Emit usage_tokens + model in result events
```

---

## Phase A — Orchestrator backend

22 tasks (~18h). Each task ends with a green test and a commit. Land all of Phase A on `feat/sprint-46-credit-pricing` branch; merge to `main` at the end of Phase A.

### Task A1: Add stripe + websockets dependencies

**Files:**
- Modify: `services/orchestrator/pyproject.toml`

- [ ] **Step 1: Add deps to pyproject.toml**

In the `dependencies` list, add three lines after `sse-starlette`:

```toml
    "stripe>=11.0.0",
    "websockets>=13.0",
    "pytest-asyncio>=0.24.0",  # move under [dependency-groups].dev instead
```

Place `stripe` and `websockets` in the top `dependencies` list; place `pytest-asyncio` in `[dependency-groups]` `dev`.

- [ ] **Step 2: Resolve & install**

Run from `services/orchestrator/`:

```bash
uv sync
```

Expected: `Installed N packages` including `stripe` and `websockets`.

- [ ] **Step 3: Verify imports**

```bash
uv run python -c "import stripe, websockets; print(stripe.VERSION, websockets.__version__)"
```

Expected: prints stripe `11.x.x` and websockets `13.x.x`.

- [ ] **Step 4: Commit**

```bash
git add services/orchestrator/pyproject.toml services/orchestrator/uv.lock
git commit -m "[s46] add stripe + websockets + pytest-asyncio deps"
```

### Task A2: Scaffold pytest test directory

**Files:**
- Create: `services/orchestrator/tests/__init__.py`
- Create: `services/orchestrator/tests/conftest.py`

- [ ] **Step 1: Create empty __init__.py**

```bash
touch services/orchestrator/tests/__init__.py
```

- [ ] **Step 2: Write conftest.py with shared fixtures**

```python
# services/orchestrator/tests/conftest.py
"""Shared pytest fixtures for orchestrator tests."""
from __future__ import annotations

import os
import tempfile
from pathlib import Path

import pytest


@pytest.fixture
def tmp_db_path(tmp_path: Path) -> str:
    """Temp SQLite path; cleaned up at end of test."""
    return str(tmp_path / "test.db")


@pytest.fixture
def db(tmp_db_path: str):
    """Fresh Db instance backed by a temp file."""
    from tally_orchestrator.service import Db
    return Db(tmp_db_path)


@pytest.fixture
def freeze_time(monkeypatch):
    """Patch time.time() in the service module to return a fixed value."""
    fixed = [1_700_000_000.0]
    def _set(t: float) -> None:
        fixed[0] = t
    import tally_orchestrator.service as svc
    monkeypatch.setattr(svc.time, "time", lambda: fixed[0])
    return _set


@pytest.fixture(autouse=True)
def _isolate_env(monkeypatch):
    """Clear env vars that would alter behavior across tests."""
    for var in ("STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET", "TALLY_PUSH_JITTER_MAX_S"):
        monkeypatch.delenv(var, raising=False)
```

- [ ] **Step 3: Sanity-check pytest discovers the dir**

```bash
cd services/orchestrator && uv run pytest tests/ --collect-only
```

Expected: `0 tests collected` (no test files yet) with no errors.

- [ ] **Step 4: Commit**

```bash
git add services/orchestrator/tests/
git commit -m "[s46] scaffold orchestrator pytest dir + shared fixtures"
```

### Task A3: Schema migration — extend `quotas` + new tables

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` (SCHEMA block at line 77; Db.__init__ at line 376)

- [ ] **Step 1: Write the failing test**

Create `services/orchestrator/tests/test_schema.py`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_schema.py -v
```

Expected: 3 FAILs (columns missing, tables missing).

- [ ] **Step 3: Add new tables to the SCHEMA constant in service.py**

Inside the `SCHEMA = """..."""` block in `service.py`, append the four new `CREATE TABLE IF NOT EXISTS` statements + their indexes (verbatim from the spec, "Schema changes — new tables" section). Append them after the existing `quotas` table definition (around line 289), before the closing triple-quote.

```sql
CREATE TABLE IF NOT EXISTS overage_purchases (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    ts REAL NOT NULL,
    credits_purchased INTEGER NOT NULL,
    cost_charged_micro_usd INTEGER NOT NULL,
    kind TEXT NOT NULL,
    stripe_payment_intent_id TEXT,
    status TEXT NOT NULL DEFAULT 'pending',
    failure_reason TEXT
);
CREATE INDEX IF NOT EXISTS idx_overage_user_ts ON overage_purchases(user_id, ts DESC);

CREATE TABLE IF NOT EXISTS notification_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    threshold INTEGER NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    last_fired_at REAL,
    created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_notif_rules_user ON notification_rules(user_id, enabled);

CREATE TABLE IF NOT EXISTS notifications (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    rule_id INTEGER,
    kind TEXT NOT NULL,
    severity TEXT NOT NULL DEFAULT 'info',
    payload_json TEXT NOT NULL,
    created_at REAL NOT NULL,
    dismissed_at REAL
);
CREATE INDEX IF NOT EXISTS idx_notifications_user ON notifications(user_id, dismissed_at, created_at DESC);

CREATE TABLE IF NOT EXISTS push_devices (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    provider TEXT NOT NULL,
    endpoint_url TEXT,
    label TEXT,
    platform TEXT,
    enabled INTEGER NOT NULL DEFAULT 1,
    last_seen_at REAL,
    created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_push_devices_user ON push_devices(user_id, enabled);
```

- [ ] **Step 4: Add idempotent ALTER TABLE blocks to Db.__init__**

In `Db.__init__` after line 440 (`self._seed_agent_roles()` call — add BEFORE that line), append a `# Sprint 46: credit-based pricing columns` comment block, then 13 try/except blocks following the existing pattern (lines 383-409 show the model):

```python
        # Sprint 46: credit-based pricing extends `quotas` with cap +
        # overage + alert columns.  All additive; existing rows get
        # NULL/default and behave as "no cap, overage off".
        _s46_quota_cols = [
            ("per_task_cap_credits", "INTEGER"),
            ("daily_spend_cap_credits", "INTEGER"),
            ("weekly_spend_cap_credits", "INTEGER"),
            ("overage_enabled", "INTEGER NOT NULL DEFAULT 0"),
            ("auto_recharge_mode", "INTEGER NOT NULL DEFAULT 0"),
            ("auto_recharge_block_credits", "INTEGER NOT NULL DEFAULT 500"),
            ("auto_recharge_monthly_cap_micro_usd", "INTEGER"),
            ("auto_recharge_spent_this_month_micro_usd", "INTEGER NOT NULL DEFAULT 0"),
            ("stripe_payment_method_id", "TEXT"),
            ("prepaid_credit_balance", "INTEGER NOT NULL DEFAULT 0"),
            ("spend_alert_threshold_pct", "INTEGER NOT NULL DEFAULT 80"),
            ("alert_80_sent_at", "REAL"),
            ("alert_100_sent_at", "REAL"),
        ]
        for col, ddl in _s46_quota_cols:
            try:
                self._conn.execute(f"ALTER TABLE quotas ADD COLUMN {col} {ddl}")
            except sqlite3.OperationalError:
                pass
```

The new CREATE TABLE statements in the SCHEMA block are `IF NOT EXISTS`, so they're already idempotent — no work needed in `__init__` for those.

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_schema.py -v
```

Expected: 3 PASS.

- [ ] **Step 6: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_schema.py
git commit -m "[s46] schema: extend quotas + add overage/notification/push tables"
```

### Task A4: Replace QUOTA_PLANS with credit-based config

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py:297-320`

- [ ] **Step 1: Write the failing test**

Create `services/orchestrator/tests/test_credits.py`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_credits.py -v
```

Expected: 6 FAILs (current QUOTA_PLANS has tasks/agent_seconds keys, not credits).

- [ ] **Step 3: Rewrite QUOTA_PLANS in service.py**

Replace `service.py:297-320` verbatim:

```python
# Sprint 46: credit-based plan config.  Replaces Sprint 33's
# tasks-per-period model — credits are units of $0.01 of Red Pill
# COGS.  Beta tiers are sold at 1.5× COGS markup (25% discount vs
# stable's 2× markup) and stay locked for the life of a subscription.
# `model_allowlist=None` means "any Red Pill model"; the Free tier
# restricts to llama-3.3 only because its credits are too few to
# safely allow premium reasoning models.
QUOTA_PLANS: dict[str, dict] = {
    "free": {
        "label": "Free",
        "price_micro_usd_monthly": 0,
        "included_credits": 50,
        "default_per_task_cap_credits": 25,
        "max_per_task_cap_credits": 50,
        "model_allowlist": {"meta-llama/llama-3.3-70b-instruct"},
        "overage_eligible": False,
        "is_beta": False,
    },
    "pro_beta": {
        "label": "Pro (Beta)",
        "price_micro_usd_monthly": 15_000_000,
        "included_credits": 1000,
        "default_per_task_cap_credits": 100,
        "max_per_task_cap_credits": None,
        "model_allowlist": None,
        "overage_eligible": True,
        "is_beta": True,
    },
    "max_beta": {
        "label": "Max (Beta)",
        "price_micro_usd_monthly": 75_000_000,
        "included_credits": 5000,
        "default_per_task_cap_credits": 500,
        "max_per_task_cap_credits": None,
        "model_allowlist": None,
        "overage_eligible": True,
        "is_beta": True,
    },
    "ultra_beta": {
        "label": "Ultra (Beta)",
        "price_micro_usd_monthly": 150_000_000,
        "included_credits": 10_000,
        "default_per_task_cap_credits": 1000,
        "max_per_task_cap_credits": None,
        "model_allowlist": None,
        "overage_eligible": True,
        "is_beta": True,
    },
    "unlimited": {
        "label": "Unlimited (admin)",
        "price_micro_usd_monthly": 0,
        "included_credits": 10**8,
        "default_per_task_cap_credits": 10**8,
        "max_per_task_cap_credits": None,
        "model_allowlist": None,
        "overage_eligible": False,
        "is_beta": False,
    },
}
```

- [ ] **Step 4: Update Clerk plan-slug recognizer to accept the new slugs**

In `clerk_billing.py:46`, change `_KNOWN_PLAN_SLUGS = {"free", "free_user", "pro", "team"}` to:

```python
_KNOWN_PLAN_SLUGS = {
    "free", "free_user", "pro", "team",  # legacy slugs (kept until Clerk dashboard is migrated)
    "pro_beta", "max_beta", "ultra_beta",  # Sprint 46 beta tiers
}
```

In `clerk_billing.py:74-77` (the `parse_plan_claim` body), the existing string-equality logic already maps unrecognised slugs to None, which falls back to `free` — no further change needed.

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_credits.py -v
```

Expected: 6 PASS.

- [ ] **Step 6: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tally_orchestrator/clerk_billing.py services/orchestrator/tests/test_credits.py
git commit -m "[s46] QUOTA_PLANS: credit-based beta tiers (free/pro/max/ultra)"
```

### Task A5: New `credits.py` module — credit math helpers

**Files:**
- Create: `services/orchestrator/tally_orchestrator/credits.py`
- Modify: `services/orchestrator/tests/test_credits.py`

- [ ] **Step 1: Write the failing tests**

Append to `services/orchestrator/tests/test_credits.py`:

```python
from tally_orchestrator.credits import (
    micro_usd_to_credits,
    credits_to_micro_usd,
    OVERAGE_CREDIT_PRICE_MICRO_USD,
    MIN_PURCHASE_CREDITS,
)


def test_micro_usd_to_credits_rounds_up():
    # 1 credit = $0.01 = 10_000 micro_usd
    assert micro_usd_to_credits(10_000) == 1
    assert micro_usd_to_credits(10_001) == 2  # round up — never undercount usage
    assert micro_usd_to_credits(9_999) == 1
    assert micro_usd_to_credits(0) == 0


def test_credits_to_micro_usd_at_overage_rate():
    # User-facing overage: $0.02/credit = 20_000 micro_usd
    assert credits_to_micro_usd(1) == 20_000
    assert credits_to_micro_usd(250) == 5_000_000  # $5 minimum


def test_overage_constants():
    assert OVERAGE_CREDIT_PRICE_MICRO_USD == 20_000
    assert MIN_PURCHASE_CREDITS == 250  # $5 floor (Stripe fixed fee economics)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_credits.py -v
```

Expected: 3 new FAILs (`credits` module not importable).

- [ ] **Step 3: Write `credits.py`**

```python
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
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_credits.py -v
```

Expected: 9 PASS (6 existing + 3 new).

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/credits.py services/orchestrator/tests/test_credits.py
git commit -m "[s46] credits.py: micro_usd↔credits conversion + overage constants"
```

### Task A6: DB methods for credit balance + prepaid + period usage

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — add four methods to the `Db` class, right after `task_cost` (~line 1389)
- Create: `services/orchestrator/tests/test_credit_balance.py`

- [ ] **Step 1: Write the failing tests**

Create `services/orchestrator/tests/test_credit_balance.py`:

```python
"""Sprint 46: credit balance / period usage / prepaid Db methods."""
import time
import pytest
from tally_orchestrator.service import Db, QUOTA_PLANS


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


def test_effective_per_task_cap_credits_uses_quota_override(db: Db):
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    # No override → falls back to plan default (100 for pro_beta)
    assert db.effective_per_task_cap_credits("u1") == 100
    db.set_per_task_cap("u1", 50)
    assert db.effective_per_task_cap_credits("u1") == 50
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_credit_balance.py -v
```

Expected: 6 FAILs (methods don't exist).

- [ ] **Step 3: Add methods to `Db` class**

Insert these methods inside the `Db` class in `service.py`, right after the `task_cost` method (currently at line ~1389):

```python
    # ── Sprint 46: credit balance + period usage + overage state ───────────

    def credits_used_this_period(self, user_id: str, period_start: float) -> int:
        """Credits consumed since `period_start`.  Derived from
        `cost_events.cost_micro_usd` (single source of truth — no
        denormalized counter on `quotas`)."""
        from .credits import micro_usd_to_credits
        row = self._conn.execute(
            "SELECT COALESCE(SUM(cost_micro_usd), 0) FROM cost_events "
            "WHERE user_id=? AND ts >= ?",
            (user_id, period_start),
        ).fetchone()
        return micro_usd_to_credits(int(row[0] or 0))

    def credits_used_in_window(self, user_id: str, since_ts: float) -> int:
        """Credits in a rolling window (used for daily / weekly cap checks)."""
        from .credits import micro_usd_to_credits
        row = self._conn.execute(
            "SELECT COALESCE(SUM(cost_micro_usd), 0) FROM cost_events "
            "WHERE user_id=? AND ts >= ?",
            (user_id, since_ts),
        ).fetchone()
        return micro_usd_to_credits(int(row[0] or 0))

    def credits_available(self, user_id: str) -> int:
        """Subscription pool remaining + prepaid balance.

        Negative values clamp to 0 — we don't allow negative
        available-credit anywhere callers might branch on `> 0`.
        """
        q = self.get_or_create_quota(user_id)
        plan = QUOTA_PLANS.get(q["plan"], QUOTA_PLANS["free"])
        used = self.credits_used_this_period(user_id, q["period_start"])
        subscription_left = max(0, plan["included_credits"] - used)
        return subscription_left + int(q.get("prepaid_credit_balance") or 0)

    def get_prepaid_balance(self, user_id: str) -> int:
        row = self._conn.execute(
            "SELECT prepaid_credit_balance FROM quotas WHERE user_id=?",
            (user_id,),
        ).fetchone()
        return int(row[0]) if row else 0

    def set_prepaid_balance(self, user_id: str, credits: int) -> None:
        self._conn.execute(
            "UPDATE quotas SET prepaid_credit_balance=?, updated_at=? WHERE user_id=?",
            (credits, time.time(), user_id),
        )

    def increment_prepaid_balance(self, user_id: str, delta: int) -> None:
        self._conn.execute(
            "UPDATE quotas SET prepaid_credit_balance = prepaid_credit_balance + ?, "
            "updated_at=? WHERE user_id=?",
            (delta, time.time(), user_id),
        )

    def consume_prepaid_balance(self, user_id: str, credits: int) -> None:
        """Decrement (clamped at 0).  Called from the cost-event insert
        path when a task's cost lands and subscription credits are
        already exhausted."""
        self._conn.execute(
            "UPDATE quotas SET prepaid_credit_balance = MAX(0, prepaid_credit_balance - ?), "
            "updated_at=? WHERE user_id=?",
            (credits, time.time(), user_id),
        )

    def effective_per_task_cap_credits(self, user_id: str) -> int:
        """Quota override wins; plan default otherwise."""
        q = self.get_or_create_quota(user_id)
        override = q.get("per_task_cap_credits")
        if override is not None:
            return int(override)
        plan = QUOTA_PLANS.get(q["plan"], QUOTA_PLANS["free"])
        return int(plan["default_per_task_cap_credits"])

    def set_per_task_cap(self, user_id: str, credits: int | None) -> None:
        self._conn.execute(
            "UPDATE quotas SET per_task_cap_credits=?, updated_at=? WHERE user_id=?",
            (credits, time.time(), user_id),
        )

    def set_daily_cap(self, user_id: str, credits: int | None) -> None:
        self._conn.execute(
            "UPDATE quotas SET daily_spend_cap_credits=?, updated_at=? WHERE user_id=?",
            (credits, time.time(), user_id),
        )

    def set_weekly_cap(self, user_id: str, credits: int | None) -> None:
        self._conn.execute(
            "UPDATE quotas SET weekly_spend_cap_credits=?, updated_at=? WHERE user_id=?",
            (credits, time.time(), user_id),
        )
```

Also extend `get_or_create_quota` (around line 1493) to surface the new columns. Update the `SELECT` columns list and the returned dict so the new fields appear:

```python
        row = self._conn.execute(
            "SELECT plan, stripe_customer_id, stripe_subscription_id, "
            "period_start, period_tasks_used, period_agent_seconds_used, updated_at, "
            "per_task_cap_credits, daily_spend_cap_credits, weekly_spend_cap_credits, "
            "overage_enabled, auto_recharge_mode, auto_recharge_block_credits, "
            "auto_recharge_monthly_cap_micro_usd, auto_recharge_spent_this_month_micro_usd, "
            "stripe_payment_method_id, prepaid_credit_balance, spend_alert_threshold_pct, "
            "alert_80_sent_at, alert_100_sent_at "
            "FROM quotas WHERE user_id=?", (user_id,),
        ).fetchone()
```

And in the return dict (both the `INSERT new row` branch and the `existing row` branch), add the new keys with defaults / column values.

For the new-row branch:

```python
            return {
                "user_id": user_id, "plan": plan,
                "stripe_customer_id": None, "stripe_subscription_id": None,
                "period_start": now, "period_tasks_used": 0,
                "period_agent_seconds_used": 0, "updated_at": now,
                "per_task_cap_credits": None,
                "daily_spend_cap_credits": None,
                "weekly_spend_cap_credits": None,
                "overage_enabled": 0,
                "auto_recharge_mode": 0,
                "auto_recharge_block_credits": 500,
                "auto_recharge_monthly_cap_micro_usd": None,
                "auto_recharge_spent_this_month_micro_usd": 0,
                "stripe_payment_method_id": None,
                "prepaid_credit_balance": 0,
                "spend_alert_threshold_pct": 80,
                "alert_80_sent_at": None,
                "alert_100_sent_at": None,
            }
```

For the existing-row branch (replace the final `return` block):

```python
        return {
            "user_id": user_id, "plan": stored_plan,
            "stripe_customer_id": row[1], "stripe_subscription_id": row[2],
            "period_start": row[3], "period_tasks_used": row[4],
            "period_agent_seconds_used": row[5], "updated_at": row[6],
            "per_task_cap_credits": row[7],
            "daily_spend_cap_credits": row[8],
            "weekly_spend_cap_credits": row[9],
            "overage_enabled": row[10],
            "auto_recharge_mode": row[11],
            "auto_recharge_block_credits": row[12],
            "auto_recharge_monthly_cap_micro_usd": row[13],
            "auto_recharge_spent_this_month_micro_usd": row[14],
            "stripe_payment_method_id": row[15],
            "prepaid_credit_balance": row[16],
            "spend_alert_threshold_pct": row[17],
            "alert_80_sent_at": row[18],
            "alert_100_sent_at": row[19],
        }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_credit_balance.py -v
```

Expected: 6 PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_credit_balance.py
git commit -m "[s46] Db: credits_used / credits_available / prepaid / caps"
```


### Task A7: Pre-submit credit gate (Checkpoint 1) + daily/weekly caps (Checkpoint 2)

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — POST /tasks handler (~line 3598)
- Create: `services/orchestrator/tests/test_credit_gates.py`

- [ ] **Step 1: Write the failing test**

Create `services/orchestrator/tests/test_credit_gates.py`:

```python
"""Sprint 46: POST /tasks pre-submit credit gates."""
import time
import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch, tmp_db_path):
    monkeypatch.setenv("TALLY_DB_PATH", tmp_db_path)
    monkeypatch.setenv("TALLY_BEARER_TOKEN", "test-token")
    monkeypatch.setenv("TALLY_REDPILL_KEY", "")  # disables architect call
    monkeypatch.setenv("TALLY_TEST_MODE", "1")    # short-circuit pool readiness
    # Import after env is set so module-level config picks up the values.
    import importlib, tally_orchestrator.service as svc
    importlib.reload(svc)
    svc.state["pool_ready"] = True
    return TestClient(svc.app)


def _headers():
    return {"Authorization": "Bearer test-token"}


def test_402_when_credits_exhausted(client, monkeypatch):
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    # User starts as pro_beta with 1000 credits.
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    # Use up all 1000.
    db.record_cost_event(
        user_id="u1", kind="architect", model="meta-llama/llama-3.3-70b-instruct",
        prompt_tokens=0, completion_tokens=0, total_tokens=0,
        cost_micro_usd=10_000_000,  # 1000 credits
    )
    # Mock the require_user dependency
    from tally_orchestrator.clerk_auth import ClerkUser
    def _mock_user():
        return ClerkUser(id="u1", source="clerk", plan="pro_beta", email="u1@x.com")
    svc.app.dependency_overrides[svc.require_user] = _mock_user
    try:
        r = client.post("/tasks", json={"description": "hi"}, headers=_headers())
        assert r.status_code == 402
        body = r.json()["detail"]
        assert body["error"] == "no_credits_remaining"
        assert body["available_credits"] == 0
    finally:
        svc.app.dependency_overrides.clear()


def test_402_when_daily_cap_reached(client):
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    db.set_daily_cap("u1", 50)
    # Use 60 credits today
    db.record_cost_event(
        user_id="u1", kind="architect", model="meta-llama/llama-3.3-70b-instruct",
        prompt_tokens=0, completion_tokens=0, total_tokens=0,
        cost_micro_usd=600_000,  # 60 credits
    )
    from tally_orchestrator.clerk_auth import ClerkUser
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="u1", source="clerk", plan="pro_beta", email="u1@x.com",
    )
    try:
        r = client.post("/tasks", json={"description": "hi"}, headers=_headers())
        assert r.status_code == 402
        assert r.json()["detail"]["error"] == "daily_cap_reached"
    finally:
        svc.app.dependency_overrides.clear()


def test_passes_when_credits_available(client, monkeypatch):
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    # Mock the orchestrator's submission path so we don't actually dispatch
    monkeypatch.setattr(svc.state["orchestrator"], "redpill_key", "")
    from tally_orchestrator.clerk_auth import ClerkUser
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="u1", source="clerk", plan="pro_beta", email="u1@x.com",
    )
    try:
        r = client.post("/tasks", json={"description": "hi"}, headers=_headers())
        assert r.status_code == 200
        assert "id" in r.json()
    finally:
        svc.app.dependency_overrides.clear()
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_credit_gates.py -v
```

Expected: 3 FAILs (current gate returns 429 with `quota_exceeded`, not 402 with `no_credits_remaining`).

- [ ] **Step 3: Replace POST /tasks gate with credit-based check**

In `service.py` around lines 3686-3707 (the current `quota_exceeded` check), replace the block with the credit gate + daily/weekly cap check. Insert this AFTER the architect call returns (after line 3685 `team_spec = None`):

```python
    # Sprint 46: credit-based pre-submit gates.  Replace the old
    # task-count cap with credit-of-COGS accounting + daily/weekly
    # spend caps.  Admin's `unlimited` plan has 10**8 included
    # credits so this check is a no-op for them.
    quota = db.get_or_create_quota(user.id, plan_hint=user.plan)
    plan_caps = QUOTA_PLANS.get(quota["plan"], QUOTA_PLANS["free"])
    available = db.credits_available(user.id)
    if available <= 0:
        # Mode 3 (full auto unlimited) auto-tops-up before failing
        mode = int(quota.get("auto_recharge_mode") or 0)
        recharged = False
        if mode == 3:
            try:
                from .stripe_direct import trigger_auto_recharge_unlimited
                await trigger_auto_recharge_unlimited(db, user.id)
                recharged = True
            except Exception as exc:
                logger.warning("auto_recharge_unlimited failed for %s: %s", user.id, exc)
                raise HTTPException(
                    status_code=503,
                    detail={"error": "auto_recharge_payment_failed",
                            "message": "Stripe unreachable, retry shortly"},
                )
        elif mode == 2:
            try:
                from .stripe_direct import trigger_auto_recharge_capped
                if await trigger_auto_recharge_capped(db, user.id):
                    recharged = True
            except Exception as exc:
                logger.warning("auto_recharge_capped failed for %s: %s", user.id, exc)
        if not recharged:
            raise HTTPException(
                status_code=402,
                detail={
                    "error": "no_credits_remaining",
                    "plan": quota["plan"],
                    "available_credits": 0,
                    "overage_enabled": bool(quota.get("overage_enabled") or 0),
                    "upgrade_action": "open_pricing_table",
                },
            )
    # Daily cap (rolling 24h)
    daily_cap = quota.get("daily_spend_cap_credits")
    if daily_cap is not None and int(daily_cap) > 0:
        day_since = time.time() - 86400
        daily_used = db.credits_used_in_window(user.id, day_since)
        if daily_used >= int(daily_cap):
            raise HTTPException(
                status_code=402,
                detail={
                    "error": "daily_cap_reached",
                    "cap_credits": int(daily_cap),
                    "used_credits": daily_used,
                },
            )
    # Weekly cap (rolling 7d)
    weekly_cap = quota.get("weekly_spend_cap_credits")
    if weekly_cap is not None and int(weekly_cap) > 0:
        week_since = time.time() - 7 * 86400
        weekly_used = db.credits_used_in_window(user.id, week_since)
        if weekly_used >= int(weekly_cap):
            raise HTTPException(
                status_code=402,
                detail={
                    "error": "weekly_cap_reached",
                    "cap_credits": int(weekly_cap),
                    "used_credits": weekly_used,
                },
            )
```

Delete the old `if quota["period_tasks_used"] >= plan_caps["tasks"]` block (lines 3692-3707). Keep `db.increment_task_count` further down — that counter is harmless and feeds the existing `/billing/usage` endpoint until we replace it in Task A14.

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_credit_gates.py -v
```

Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_credit_gates.py
git commit -m "[s46] POST /tasks: credit gate (Checkpoint 1) + daily/weekly caps (Checkpoint 2)"
```

### Task A8: Architect model allowlist (Checkpoint 3)

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/architect.py:52-115`
- Modify: `services/orchestrator/tally_orchestrator/service.py` — pass allowlist into architect_team call
- Create: `services/orchestrator/tests/test_architect_allowlist.py`

- [ ] **Step 1: Write the failing test**

Create `services/orchestrator/tests/test_architect_allowlist.py`:

```python
"""Sprint 46: architect honors model_allowlist (Checkpoint 3)."""
from unittest.mock import patch
from tally_orchestrator.architect import architect_team


def test_allowlist_overrides_architect_model_picks(monkeypatch):
    # Architect returns a team that picks a premium model
    raw_team = (
        '{"agents": [{"role": "Coder", "model": "moonshotai/kimi-k2.6-instruct"}], '
        '"workflow": "Coder"}'
    )
    monkeypatch.setattr(
        "tally_orchestrator.architect._call_redpill",
        lambda **kw: (raw_team, {"prompt_tokens": 10, "completion_tokens": 20, "total_tokens": 30}),
    )
    palette = [
        {"name": "Coder", "description": "writes code", "default_model": "moonshotai/kimi-k2.6-instruct",
         "default_tools": ["bash"], "system_prompt": "code please"},
    ]
    out = architect_team(
        description="implement foo",
        palette=palette,
        redpill_key="k",
        model_allowlist={"meta-llama/llama-3.3-70b-instruct"},
    )
    # All agents should have been forced to the allowlist model
    for agent in out["agents"]:
        assert agent["model"] == "meta-llama/llama-3.3-70b-instruct"


def test_no_allowlist_keeps_architect_picks(monkeypatch):
    raw_team = (
        '{"agents": [{"role": "Coder", "model": "moonshotai/kimi-k2.6-instruct"}], '
        '"workflow": "Coder"}'
    )
    monkeypatch.setattr(
        "tally_orchestrator.architect._call_redpill",
        lambda **kw: (raw_team, {"total_tokens": 30}),
    )
    palette = [
        {"name": "Coder", "description": "writes code", "default_model": "moonshotai/kimi-k2.6-instruct",
         "default_tools": ["bash"], "system_prompt": "code please"},
    ]
    out = architect_team(
        description="implement foo",
        palette=palette,
        redpill_key="k",
        model_allowlist=None,
    )
    assert out["agents"][0]["model"] == "moonshotai/kimi-k2.6-instruct"
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_architect_allowlist.py -v
```

Expected: 2 FAILs (`model_allowlist` is not a parameter of `architect_team`).

- [ ] **Step 3: Add `model_allowlist` parameter to architect_team**

In `services/orchestrator/tally_orchestrator/architect.py`, modify the signature (line 52-61) to add `model_allowlist`:

```python
def architect_team(
    *,
    description: str,
    palette: list[dict],
    redpill_key: str,
    redpill_base: str = "https://api.redpill.ai/v1",
    model: str = ARCHITECT_MODEL,
    templates: list[dict] | None = None,
    cost_recorder: Callable[[str, dict], None] | None = None,
    model_allowlist: set[str] | None = None,
) -> dict:
```

After `cleaned = _validate_team_spec(parsed, palette_names)` (around line 104) and the `None` check, add allowlist enforcement:

```python
    # Sprint 46: free tier restricts to llama-only.  If the architect
    # picked anything else, silently override each agent's model.  The
    # allowlist's first member is the fallback target.
    if model_allowlist:
        fallback_model = next(iter(model_allowlist))
        for agent in cleaned.get("agents", []):
            picked = agent.get("model")
            if picked is not None and picked not in model_allowlist:
                logger.info(
                    "allowlist: replacing architect's pick %r with %r for role=%s",
                    picked, fallback_model, agent.get("role"),
                )
                agent["model"] = fallback_model
```

- [ ] **Step 4: Wire allowlist into the POST /tasks caller**

In `service.py` (around line 3672), update the `architect_team(...)` call to pass the allowlist from the user's plan:

```python
            plan_caps_for_arch = QUOTA_PLANS.get(quota["plan"], QUOTA_PLANS["free"])
            team_spec = await asyncio.to_thread(
                architect_team,
                description=body.description,
                palette=palette,
                redpill_key=orch.redpill_key,
                redpill_base=orch.redpill_base,
                templates=templates,
                cost_recorder=_record_architect_cost,
                model_allowlist=plan_caps_for_arch.get("model_allowlist"),
            )
```

Note: this line moved because the credit-gate block in Task A7 already computes `quota` and `plan_caps`. Reuse `plan_caps`.

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_architect_allowlist.py -v
```

Expected: 2 PASS.

- [ ] **Step 6: Commit**

```bash
git add services/orchestrator/tally_orchestrator/architect.py services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_architect_allowlist.py
git commit -m "[s46] architect: model_allowlist for free-tier llama-only routing"
```

### Task A9: Pre-dispatch estimated-cost check (Checkpoint 4)

**Files:**
- Create: `services/orchestrator/tally_orchestrator/cost_estimate.py`
- Modify: `services/orchestrator/tally_orchestrator/service.py` — call estimate before dispatching team
- Create: `services/orchestrator/tests/test_cost_estimate.py`

- [ ] **Step 1: Write the failing test**

Create `services/orchestrator/tests/test_cost_estimate.py`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_cost_estimate.py -v
```

Expected: 3 FAILs (module doesn't exist).

- [ ] **Step 3: Write `cost_estimate.py`**

```python
# services/orchestrator/tally_orchestrator/cost_estimate.py
"""Sprint 46: per-team cost estimation.

Placeholder heuristic.  Sprint 1.5 will calibrate constants from
real samples (see spec "Open items" §1).  The shape of the returned
dict is stable so callers don't change.
"""
from __future__ import annotations

from .cost import PRICE_TABLE
from .credits import micro_usd_to_credits

# Placeholder estimates for each agent role's expected token usage.
# Tuned by hand from a few Sprint 42 sample tasks; replace with
# median-from-10-runs constants in Sprint 1.5.
DEFAULT_PROMPT_TOKENS = 4000
DEFAULT_COMPLETION_TOKENS = 800

# Tokens scale with description length (rough linear fit).
PROMPT_TOKENS_PER_CHAR = 4
COMPLETION_TOKENS_PER_CHAR = 1


def _agent_estimate_micro_usd(model: str, description_length: int) -> int:
    """Estimate micro_usd for one agent given the description size."""
    prompt = max(DEFAULT_PROMPT_TOKENS, description_length * PROMPT_TOKENS_PER_CHAR)
    completion = max(DEFAULT_COMPLETION_TOKENS, description_length * COMPLETION_TOKENS_PER_CHAR)
    prices = PRICE_TABLE.get(model) or (0.59, 0.79)  # llama fallback
    usd = (prompt * prices[0] + completion * prices[1]) / 1_000_000
    return int(round(usd * 1_000_000))


def estimate_team_cost_credits(team_spec: dict, description_length: int) -> dict:
    """Estimate the credit cost of a team_spec.

    Returns {"total_credits": int, "per_agent": [{"role": str,
    "model": str, "credits": int}, ...]}.
    """
    out_per_agent: list[dict] = []
    total_micro = 0
    for agent in team_spec.get("agents", []) or []:
        model = agent.get("model") or "meta-llama/llama-3.3-70b-instruct"
        micro = _agent_estimate_micro_usd(model, description_length)
        total_micro += micro
        out_per_agent.append({
            "role": agent.get("role", ""),
            "model": model,
            "credits": micro_usd_to_credits(micro),
        })
    return {
        "total_credits": micro_usd_to_credits(total_micro),
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
```

- [ ] **Step 4: Wire the estimate into POST /tasks**

In `service.py`, immediately after `team_spec` is finalized (after the architect call returns, before `db.create_task`), insert the pre-dispatch check:

```python
    # Sprint 46: Checkpoint 4 — estimated-cost pre-check.  If the team
    # team_spec's estimated cost exceeds the user's per-task cap, try
    # rerouting to cheap models; if still over, abort with a 402
    # before we burn agent compute.
    from .cost_estimate import estimate_team_cost_credits, reroute_to_cheap_models
    if team_spec and team_spec.get("agents"):
        cap = db.effective_per_task_cap_credits(user.id)
        estimate = estimate_team_cost_credits(team_spec, len(body.description))
        if estimate["total_credits"] > cap:
            # Try one re-route pass to llama-only
            cheap_allowlist = {"meta-llama/llama-3.3-70b-instruct"}
            team_spec = reroute_to_cheap_models(team_spec, cheap_allowlist)
            estimate = estimate_team_cost_credits(team_spec, len(body.description))
        if estimate["total_credits"] > cap:
            raise HTTPException(
                status_code=402,
                detail={
                    "error": "task_cap_estimated_exceeds",
                    "estimated_credits": estimate["total_credits"],
                    "cap_credits": cap,
                    "per_agent": estimate["per_agent"],
                },
            )
```

- [ ] **Step 5: Add a test for the pre-dispatch path**

Append to `tests/test_credit_gates.py`:

```python
def test_estimated_cost_over_cap_returns_402(client):
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    db.set_per_task_cap("u1", 1)  # ridiculously low
    from tally_orchestrator.clerk_auth import ClerkUser
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="u1", source="clerk", plan="pro_beta", email="u1@x.com",
    )
    try:
        # Without architect (REDPILL_KEY empty), the path that triggers
        # cost estimate runs on user-supplied team_spec.
        r = client.post(
            "/tasks",
            json={"description": "x" * 5000,
                  "team_spec": {"agents": [{"role": "Coder", "model": "moonshotai/kimi-k2.6-instruct"}]}},
            headers=_headers(),
        )
        assert r.status_code == 402
        assert r.json()["detail"]["error"] == "task_cap_estimated_exceeds"
    finally:
        svc.app.dependency_overrides.clear()
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_cost_estimate.py tests/test_credit_gates.py -v
```

Expected: 7 PASS (3 estimate + 4 gate).

- [ ] **Step 7: Commit**

```bash
git add services/orchestrator/tally_orchestrator/cost_estimate.py services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_cost_estimate.py services/orchestrator/tests/test_credit_gates.py
git commit -m "[s46] cost_estimate: per-team credit estimate + Checkpoint 4 pre-dispatch"
```

### Task A10: Mid-run per-task cap abort (Checkpoint 5)

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — `Orchestrator._on_agent_complete` (the post-completion stage-advance code around line 2624)
- Create: `services/orchestrator/tests/test_mid_run_cap.py`

- [ ] **Step 1: Write the failing test**

Create `services/orchestrator/tests/test_mid_run_cap.py`:

```python
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
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_mid_run_cap.py -v
```

Expected: 2 PASS (these only test the predicate; the orchestrator-loop test is at integration level). Test PASSING here is fine — it's a smoke check of the data layer. Move to Step 3 for the orchestrator change.

- [ ] **Step 3: Insert mid-run abort logic into `_on_agent_complete`**

In `service.py` find the line around 2624-2655 where stage-advance happens after an agent completes. Right BEFORE the stage-advance block (after `self.db.mark_agent_completed(...)` and before `self.db.list_agents(task_id)`), insert:

```python
        # Sprint 46: Checkpoint 5 — mid-run per-task cap.  If the
        # cumulative cost for this task has crossed the user's per-task
        # cap, abort the remaining stages.  S41's task_artifacts
        # retention rule applies — partials stay.
        try:
            from .credits import micro_usd_to_credits
            task_cost_micro = self.db.task_cost(task_id)["total_micro_usd"]
            task_cost_credits = micro_usd_to_credits(task_cost_micro)
            user_id = task.get("user_id") or "legacy-admin"
            effective_cap = self.db.effective_per_task_cap_credits(user_id)
            if task_cost_credits > effective_cap:
                self.db.mark_failed(
                    task_id,
                    f"cost cap reached: {task_cost_credits} > {effective_cap}",
                )
                self._task_artifacts.pop(task_id, None)
                await self._publish_status(task_id, "aborted_cost_cap", {
                    "cost_credits": task_cost_credits,
                    "cap_credits": effective_cap,
                })
                logger.info(
                    "task %s aborted: cost cap %d > %d",
                    task_id[:8], task_cost_credits, effective_cap,
                )
                return
        except Exception as exc:
            # Cost cap is safety, not feature — never crash the
            # orchestrator if accounting fails.
            logger.warning("cost cap check failed for task %s: %s", task_id[:8], exc)
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_mid_run_cap.py -v
```

Expected: 2 PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_mid_run_cap.py
git commit -m "[s46] Checkpoint 5: mid-run per-task cap abort with aborted_cost_cap status"
```

### Task A11: `stripe_direct.py` scaffold — Checkout + idempotency

**Files:**
- Create: `services/orchestrator/tally_orchestrator/stripe_direct.py`
- Create: `services/orchestrator/tests/test_stripe_direct.py`

- [ ] **Step 1: Write the failing test**

Create `services/orchestrator/tests/test_stripe_direct.py`:

```python
"""Sprint 46: stripe_direct.py — Checkout Session + off-session PaymentIntent."""
from unittest.mock import MagicMock, patch
import pytest


def test_module_imports_when_key_unset(monkeypatch):
    """stripe_direct should be importable even if STRIPE_SECRET_KEY is missing;
    individual functions raise StripeNotConfiguredError on use."""
    monkeypatch.delenv("STRIPE_SECRET_KEY", raising=False)
    from tally_orchestrator import stripe_direct
    assert stripe_direct is not None


def test_create_checkout_session_calls_stripe(monkeypatch, db):
    monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_test_xxx")
    db.get_or_create_quota("u1", plan_hint="pro_beta")

    fake = MagicMock()
    fake.Checkout.Session.create = MagicMock(
        return_value=MagicMock(id="cs_test_123", url="https://checkout.stripe.com/cs_test_123"),
    )
    with patch.dict("sys.modules", {"stripe": fake}):
        import importlib, tally_orchestrator.stripe_direct as sd
        importlib.reload(sd)
        out = sd.create_credits_checkout_session(
            db, user_id="u1", credits=500, success_url="x://success", cancel_url="x://cancel",
        )
        assert out["url"].startswith("https://checkout.stripe.com/")
        assert out["session_id"] == "cs_test_123"
    fake.Checkout.Session.create.assert_called_once()


def test_idempotency_key_format():
    from tally_orchestrator.stripe_direct import recharge_idempotency_key
    key = recharge_idempotency_key(user_id="u1", period_start=1_700_000_000.0, already_spent=500)
    assert key == "recharge_u1_1700000000_500"


def test_unlimited_recharge_raises_when_stripe_down(monkeypatch, db):
    monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_test_xxx")
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    db._conn.execute(
        "UPDATE quotas SET auto_recharge_mode=3, stripe_payment_method_id=?, "
        "stripe_customer_id=? WHERE user_id=?",
        ("pm_test", "cus_test", "u1"),
    )

    fake = MagicMock()
    fake.error = MagicMock()
    fake.error.APIConnectionError = Exception
    fake.PaymentIntent.create = MagicMock(side_effect=Exception("connection failed"))
    with patch.dict("sys.modules", {"stripe": fake}):
        import importlib, tally_orchestrator.stripe_direct as sd
        importlib.reload(sd)
        import asyncio
        with pytest.raises(Exception):
            asyncio.run(sd.trigger_auto_recharge_unlimited(db, "u1"))
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_stripe_direct.py -v
```

Expected: 4 FAILs (module doesn't exist).

- [ ] **Step 3: Write `stripe_direct.py`**

```python
# services/orchestrator/tally_orchestrator/stripe_direct.py
"""Sprint 46: direct Stripe integration for one-time credit purchases
and off-session auto-recharge.

Path resolved before implementation (spec §"Stripe access path"):
[fill in once Clerk dashboard is checked — either restricted
sk_*** key, or fallback to Clerk Billing metered subscription items].

Idempotency: every off-session PaymentIntent.create uses
`recharge_{user_id}_{int(period_start)}_{already_spent}` so retries
in tight loops collapse into a single charge.

Mode-3 (unlimited auto-recharge) + Stripe outage: the API exception
propagates; the caller in POST /tasks maps it to 503.  No credit is
ever granted speculatively.  This is the "never spend more than we
make" invariant.
"""
from __future__ import annotations

import asyncio
import logging
import os
import time
from typing import TYPE_CHECKING

from .credits import OVERAGE_CREDIT_PRICE_MICRO_USD, MIN_PURCHASE_CREDITS

if TYPE_CHECKING:
    from .service import Db

logger = logging.getLogger("tally.stripe_direct")


class StripeNotConfiguredError(RuntimeError):
    """STRIPE_SECRET_KEY missing — Stripe paths cannot run."""


def _stripe():
    """Return the configured stripe module or raise."""
    key = os.environ.get("STRIPE_SECRET_KEY", "").strip()
    if not key:
        raise StripeNotConfiguredError("STRIPE_SECRET_KEY not configured")
    import stripe
    stripe.api_key = key
    return stripe


def recharge_idempotency_key(*, user_id: str, period_start: float, already_spent: int) -> str:
    """Stable key for off-session PaymentIntent retries."""
    return f"recharge_{user_id}_{int(period_start)}_{already_spent}"


def create_credits_checkout_session(
    db: "Db",
    *,
    user_id: str,
    credits: int,
    success_url: str,
    cancel_url: str,
) -> dict:
    """One-time credit purchase via hosted Checkout Session.

    Returns {"session_id": str, "url": str}.  Caller hands the URL
    to the Flutter client; Stripe redirects to `success_url` on
    completion and the webhook handler credits the prepaid balance.
    """
    if credits < MIN_PURCHASE_CREDITS:
        raise ValueError(
            f"minimum purchase is {MIN_PURCHASE_CREDITS} credits "
            f"(${MIN_PURCHASE_CREDITS * OVERAGE_CREDIT_PRICE_MICRO_USD // 10000 / 100:.2f})"
        )
    stripe = _stripe()
    quota = db.get_or_create_quota(user_id)
    amount_cents = credits * OVERAGE_CREDIT_PRICE_MICRO_USD // 10_000  # micro_usd → cents
    session = stripe.Checkout.Session.create(
        mode="payment",
        success_url=success_url,
        cancel_url=cancel_url,
        customer=quota.get("stripe_customer_id"),  # None creates a new one
        line_items=[{
            "price_data": {
                "currency": "usd",
                "product_data": {"name": f"{credits} Tally credits"},
                "unit_amount": amount_cents,
            },
            "quantity": 1,
        }],
        metadata={
            "user_id": user_id,
            "credits": str(credits),
            "purchase_kind": "one_time",
        },
    )
    db._conn.execute(
        "INSERT INTO overage_purchases "
        "(user_id, ts, credits_purchased, cost_charged_micro_usd, kind, status, stripe_payment_intent_id) "
        "VALUES (?, ?, ?, ?, 'one_time', 'pending', ?)",
        (
            user_id, time.time(), credits,
            credits * OVERAGE_CREDIT_PRICE_MICRO_USD,
            getattr(session, "payment_intent", None),
        ),
    )
    return {"session_id": session.id, "url": session.url}


def create_setup_session(
    db: "Db",
    *,
    user_id: str,
    success_url: str,
    cancel_url: str,
) -> dict:
    """Setup-mode Checkout for saving a card without charging.

    Used by Modes 2 + 3 to capture a payment method that we later
    charge off-session.
    """
    stripe = _stripe()
    quota = db.get_or_create_quota(user_id)
    session = stripe.Checkout.Session.create(
        mode="setup",
        success_url=success_url,
        cancel_url=cancel_url,
        customer=quota.get("stripe_customer_id"),
        metadata={
            "user_id": user_id,
            "purchase_kind": "auto_recharge_setup",
        },
    )
    return {"session_id": session.id, "url": session.url}


async def trigger_auto_recharge_unlimited(db: "Db", user_id: str) -> int:
    """Mode 3: unlimited auto-recharge.  Buys one block.  Raises on
    any Stripe failure — caller must NOT credit speculatively."""
    return await _trigger_off_session_charge(db, user_id, capped=False)


async def trigger_auto_recharge_capped(db: "Db", user_id: str) -> bool:
    """Mode 2: capped auto-recharge.  Returns True if a charge fired;
    False if monthly cap would be exceeded.  Raises on Stripe failure."""
    quota = db.get_or_create_quota(user_id)
    cap = quota.get("auto_recharge_monthly_cap_micro_usd")
    spent = int(quota.get("auto_recharge_spent_this_month_micro_usd") or 0)
    block_credits = int(quota.get("auto_recharge_block_credits") or 500)
    block_cost = block_credits * OVERAGE_CREDIT_PRICE_MICRO_USD
    if cap is not None and (spent + block_cost) > int(cap):
        logger.info(
            "auto_recharge_capped: user=%s would exceed monthly cap (%d + %d > %d)",
            user_id, spent, block_cost, int(cap),
        )
        return False
    await _trigger_off_session_charge(db, user_id, capped=True)
    return True


async def _trigger_off_session_charge(db: "Db", user_id: str, *, capped: bool) -> int:
    """Common path for both auto-recharge modes."""
    stripe = _stripe()
    quota = db.get_or_create_quota(user_id)
    pm = quota.get("stripe_payment_method_id")
    customer = quota.get("stripe_customer_id")
    if not pm or not customer:
        raise RuntimeError(f"user {user_id} has no saved card for auto-recharge")
    block_credits = int(quota.get("auto_recharge_block_credits") or 500)
    amount_micro = block_credits * OVERAGE_CREDIT_PRICE_MICRO_USD
    amount_cents = amount_micro // 10_000
    already_spent = int(quota.get("auto_recharge_spent_this_month_micro_usd") or 0)
    key = recharge_idempotency_key(
        user_id=user_id, period_start=quota["period_start"], already_spent=already_spent,
    )

    def _create_pi():
        return stripe.PaymentIntent.create(
            amount=amount_cents, currency="usd",
            customer=customer, payment_method=pm,
            off_session=True, confirm=True,
            idempotency_key=key,
            metadata={
                "user_id": user_id,
                "credits": str(block_credits),
                "purchase_kind": "auto_recharge" + ("_capped" if capped else "_unlimited"),
            },
        )

    pi = await asyncio.to_thread(_create_pi)
    # Optimistically record the pending purchase.  Webhook
    # `payment_intent.succeeded` finalizes prepaid_credit_balance.
    db._conn.execute(
        "INSERT INTO overage_purchases "
        "(user_id, ts, credits_purchased, cost_charged_micro_usd, kind, "
        "stripe_payment_intent_id, status) "
        "VALUES (?, ?, ?, ?, ?, ?, 'pending')",
        (
            user_id, time.time(), block_credits, amount_micro,
            "auto_recharge" + ("_capped" if capped else "_unlimited"),
            pi.id,
        ),
    )
    db._conn.execute(
        "UPDATE quotas SET auto_recharge_spent_this_month_micro_usd = "
        "auto_recharge_spent_this_month_micro_usd + ?, updated_at=? WHERE user_id=?",
        (amount_micro, time.time(), user_id),
    )
    logger.info(
        "auto_recharge fired: user=%s pi=%s credits=%d capped=%s",
        user_id, pi.id, block_credits, capped,
    )
    return block_credits
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_stripe_direct.py -v
```

Expected: 4 PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/stripe_direct.py services/orchestrator/tests/test_stripe_direct.py
git commit -m "[s46] stripe_direct: Checkout Session + off-session PaymentIntent (Modes 1/2/3)"
```


### Task A12: Billing endpoints — credits balance, checkout, auto-recharge setup, caps

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — add 7 routes near existing `/billing/cost`
- Create: `services/orchestrator/tests/test_billing_routes.py`

- [ ] **Step 1: Write the failing tests**

Create `services/orchestrator/tests/test_billing_routes.py`:

```python
"""Sprint 46: REST endpoints for credit balance, billing, caps."""
import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch, tmp_db_path):
    monkeypatch.setenv("TALLY_DB_PATH", tmp_db_path)
    monkeypatch.setenv("TALLY_BEARER_TOKEN", "test-token")
    monkeypatch.setenv("TALLY_REDPILL_KEY", "")
    monkeypatch.setenv("TALLY_TEST_MODE", "1")
    monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_test_xxx")
    import importlib, tally_orchestrator.service as svc
    importlib.reload(svc)
    svc.state["pool_ready"] = True
    from tally_orchestrator.clerk_auth import ClerkUser
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="u1", source="clerk", plan="pro_beta", email="u1@x.com",
    )
    yield TestClient(svc.app)
    svc.app.dependency_overrides.clear()


def test_get_credits_returns_balance(client):
    r = client.get("/billing/credits")
    assert r.status_code == 200
    body = r.json()
    assert body["plan"] == "pro_beta"
    assert body["included_credits"] == 1000
    assert body["used_credits"] == 0
    assert body["available_credits"] == 1000
    assert body["prepaid_credit_balance"] == 0


def test_get_caps_returns_defaults(client):
    r = client.get("/billing/caps")
    assert r.status_code == 200
    body = r.json()
    assert body["per_task_cap_credits"] == 100  # pro_beta default
    assert body["daily_spend_cap_credits"] is None
    assert body["weekly_spend_cap_credits"] is None


def test_patch_caps_persists(client):
    r = client.patch("/billing/caps", json={
        "per_task_cap_credits": 200,
        "daily_spend_cap_credits": 50,
    })
    assert r.status_code == 200
    r2 = client.get("/billing/caps")
    body = r2.json()
    assert body["per_task_cap_credits"] == 200
    assert body["daily_spend_cap_credits"] == 50


def test_post_credits_checkout_under_minimum_returns_400(client):
    r = client.post("/billing/credits/checkout", json={"credits": 100})
    assert r.status_code == 400
    assert "minimum" in r.json()["detail"].lower()


def test_post_credits_checkout_returns_stripe_url(client, monkeypatch):
    from unittest.mock import MagicMock
    fake_session = MagicMock(id="cs_test_456", url="https://checkout.stripe.com/cs_test_456")
    monkeypatch.setattr(
        "tally_orchestrator.stripe_direct.create_credits_checkout_session",
        lambda db, **kw: {"session_id": "cs_test_456", "url": "https://checkout.stripe.com/cs_test_456"},
    )
    r = client.post("/billing/credits/checkout", json={
        "credits": 500,
        "success_url": "tallycoding://billing/success",
        "cancel_url": "tallycoding://billing/cancel",
    })
    assert r.status_code == 200
    assert r.json()["url"].startswith("https://checkout.stripe.com/")


def test_patch_auto_recharge_persists(client):
    r = client.patch("/billing/auto-recharge", json={
        "mode": 2,
        "block_credits": 1000,
        "monthly_cap_micro_usd": 50_000_000,
    })
    assert r.status_code == 200
    r2 = client.get("/billing/credits")
    body = r2.json()
    assert body["auto_recharge_mode"] == 2
    assert body["auto_recharge_block_credits"] == 1000
    assert body["auto_recharge_monthly_cap_micro_usd"] == 50_000_000
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_billing_routes.py -v
```

Expected: 6 FAILs (routes don't exist).

- [ ] **Step 3: Add Pydantic models near other request models**

In `service.py` near line 348 (right after `class TaskResponse`), add:

```python
class CreditsCheckoutRequest(BaseModel):
    credits: int
    success_url: str = "tallycoding://billing/success"
    cancel_url: str = "tallycoding://billing/cancel"


class AutoRechargeSetupRequest(BaseModel):
    success_url: str = "tallycoding://billing/auto-recharge/success"
    cancel_url: str = "tallycoding://billing/auto-recharge/cancel"


class AutoRechargePatchRequest(BaseModel):
    mode: int | None = None  # 0, 1, 2, 3
    block_credits: int | None = None
    monthly_cap_micro_usd: int | None = None


class CapsPatchRequest(BaseModel):
    per_task_cap_credits: int | None = None
    daily_spend_cap_credits: int | None = None
    weekly_spend_cap_credits: int | None = None
```

- [ ] **Step 4: Add routes near `/billing/cost`**

In `service.py` after line 4537 (`/billing/cost` handler), add:

```python
@app.get("/billing/credits")
async def get_credits_balance(
    user: ClerkUser = Depends(require_user),
) -> dict:
    """Sprint 46: credit balance + plan summary for the billing screen."""
    db: Db = state["db"]
    quota = db.get_or_create_quota(user.id, plan_hint=user.plan)
    plan = QUOTA_PLANS.get(quota["plan"], QUOTA_PLANS["free"])
    used = db.credits_used_this_period(user.id, quota["period_start"])
    available = db.credits_available(user.id)
    return {
        "plan": quota["plan"],
        "plan_label": plan["label"],
        "is_beta": plan.get("is_beta", False),
        "period_start": quota["period_start"],
        "included_credits": plan["included_credits"],
        "used_credits": used,
        "available_credits": available,
        "prepaid_credit_balance": int(quota.get("prepaid_credit_balance") or 0),
        "overage_enabled": bool(quota.get("overage_enabled") or 0),
        "auto_recharge_mode": int(quota.get("auto_recharge_mode") or 0),
        "auto_recharge_block_credits": int(quota.get("auto_recharge_block_credits") or 500),
        "auto_recharge_monthly_cap_micro_usd": quota.get("auto_recharge_monthly_cap_micro_usd"),
        "auto_recharge_spent_this_month_micro_usd": int(
            quota.get("auto_recharge_spent_this_month_micro_usd") or 0
        ),
        "stripe_payment_method_id": quota.get("stripe_payment_method_id"),
        "spend_alert_threshold_pct": int(quota.get("spend_alert_threshold_pct") or 80),
    }


@app.get("/billing/caps")
async def get_caps(user: ClerkUser = Depends(require_user)) -> dict:
    db: Db = state["db"]
    quota = db.get_or_create_quota(user.id, plan_hint=user.plan)
    return {
        "per_task_cap_credits": db.effective_per_task_cap_credits(user.id),
        "daily_spend_cap_credits": quota.get("daily_spend_cap_credits"),
        "weekly_spend_cap_credits": quota.get("weekly_spend_cap_credits"),
    }


@app.patch("/billing/caps")
async def patch_caps(
    body: CapsPatchRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    db: Db = state["db"]
    db.get_or_create_quota(user.id, plan_hint=user.plan)
    if body.per_task_cap_credits is not None:
        plan = QUOTA_PLANS.get(user.plan or "free", QUOTA_PLANS["free"])
        max_cap = plan.get("max_per_task_cap_credits")
        if max_cap is not None and body.per_task_cap_credits > max_cap:
            raise HTTPException(
                400, f"per_task_cap exceeds plan max ({max_cap})",
            )
        db.set_per_task_cap(user.id, body.per_task_cap_credits)
    if body.daily_spend_cap_credits is not None:
        db.set_daily_cap(user.id, body.daily_spend_cap_credits)
    if body.weekly_spend_cap_credits is not None:
        db.set_weekly_cap(user.id, body.weekly_spend_cap_credits)
    return await get_caps(user=user)


@app.post("/billing/credits/checkout")
async def post_credits_checkout(
    body: CreditsCheckoutRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    db: Db = state["db"]
    from .stripe_direct import (
        create_credits_checkout_session, StripeNotConfiguredError,
    )
    try:
        out = create_credits_checkout_session(
            db, user_id=user.id, credits=body.credits,
            success_url=body.success_url, cancel_url=body.cancel_url,
        )
    except ValueError as exc:
        raise HTTPException(400, str(exc))
    except StripeNotConfiguredError:
        raise HTTPException(503, "Stripe billing not configured")
    return out


@app.post("/billing/auto-recharge/setup")
async def post_auto_recharge_setup(
    body: AutoRechargeSetupRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    db: Db = state["db"]
    from .stripe_direct import create_setup_session, StripeNotConfiguredError
    try:
        return create_setup_session(
            db, user_id=user.id,
            success_url=body.success_url, cancel_url=body.cancel_url,
        )
    except StripeNotConfiguredError:
        raise HTTPException(503, "Stripe billing not configured")


@app.patch("/billing/auto-recharge")
async def patch_auto_recharge(
    body: AutoRechargePatchRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    db: Db = state["db"]
    db.get_or_create_quota(user.id, plan_hint=user.plan)
    fields: list[str] = []
    values: list = []
    if body.mode is not None:
        if body.mode not in (0, 1, 2, 3):
            raise HTTPException(400, "mode must be 0, 1, 2, or 3")
        fields.append("auto_recharge_mode=?")
        values.append(body.mode)
        # Mode 0 also disables overage; modes 1/2/3 enable it.
        fields.append("overage_enabled=?")
        values.append(0 if body.mode == 0 else 1)
    if body.block_credits is not None:
        if body.block_credits < 250:
            raise HTTPException(400, "block_credits minimum is 250 ($5)")
        fields.append("auto_recharge_block_credits=?")
        values.append(body.block_credits)
    if body.monthly_cap_micro_usd is not None:
        fields.append("auto_recharge_monthly_cap_micro_usd=?")
        values.append(body.monthly_cap_micro_usd)
    if not fields:
        raise HTTPException(400, "no fields to update")
    fields.append("updated_at=?")
    values.append(time.time())
    values.append(user.id)
    db._conn.execute(
        f"UPDATE quotas SET {', '.join(fields)} WHERE user_id=?", values,
    )
    return await get_credits_balance(user=user)
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_billing_routes.py -v
```

Expected: 6 PASS.

- [ ] **Step 6: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_billing_routes.py
git commit -m "[s46] /billing/credits, /billing/caps, /billing/credits/checkout, /billing/auto-recharge"
```

### Task A13: Stripe webhook handler

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — add `/webhooks/stripe` route
- Create: `services/orchestrator/tests/test_stripe_webhook.py`

- [ ] **Step 1: Write the failing tests**

Create `services/orchestrator/tests/test_stripe_webhook.py`:

```python
"""Sprint 46: Stripe webhook handler."""
import json
from unittest.mock import patch
import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch, tmp_db_path):
    monkeypatch.setenv("TALLY_DB_PATH", tmp_db_path)
    monkeypatch.setenv("TALLY_BEARER_TOKEN", "test-token")
    monkeypatch.setenv("STRIPE_SECRET_KEY", "sk_test_xxx")
    monkeypatch.setenv("STRIPE_WEBHOOK_SECRET", "whsec_test")
    import importlib, tally_orchestrator.service as svc
    importlib.reload(svc)
    svc.state["pool_ready"] = True
    return TestClient(svc.app)


def _fake_event(evt_type: str, data: dict) -> dict:
    return {
        "id": "evt_test_1",
        "type": evt_type,
        "data": {"object": data},
    }


def test_checkout_completed_credits_user(client, monkeypatch):
    """checkout.session.completed → prepaid_credit_balance += credits."""
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    db._conn.execute(
        "INSERT INTO overage_purchases "
        "(user_id, ts, credits_purchased, cost_charged_micro_usd, kind, "
        "stripe_payment_intent_id, status) "
        "VALUES ('u1', 0, 500, 10000000, 'one_time', 'pi_test_1', 'pending')",
    )
    event = _fake_event("checkout.session.completed", {
        "id": "cs_test_1",
        "metadata": {"user_id": "u1", "credits": "500", "purchase_kind": "one_time"},
        "payment_intent": "pi_test_1",
    })
    monkeypatch.setattr(
        "tally_orchestrator.service._verify_stripe_signature",
        lambda payload, sig: event,
    )
    r = client.post(
        "/webhooks/stripe",
        content=json.dumps(event).encode(),
        headers={"stripe-signature": "t=0,v1=fake"},
    )
    assert r.status_code == 200
    assert db.get_prepaid_balance("u1") == 500


def test_setup_intent_succeeded_saves_payment_method(client, monkeypatch):
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    event = _fake_event("setup_intent.succeeded", {
        "id": "seti_test_1",
        "payment_method": "pm_test_1",
        "customer": "cus_test_1",
        "metadata": {"user_id": "u1"},
    })
    monkeypatch.setattr(
        "tally_orchestrator.service._verify_stripe_signature",
        lambda payload, sig: event,
    )
    r = client.post(
        "/webhooks/stripe",
        content=json.dumps(event).encode(),
        headers={"stripe-signature": "t=0,v1=fake"},
    )
    assert r.status_code == 200
    row = db._conn.execute(
        "SELECT stripe_payment_method_id, stripe_customer_id FROM quotas WHERE user_id='u1'"
    ).fetchone()
    assert row[0] == "pm_test_1"
    assert row[1] == "cus_test_1"


def test_payment_intent_failed_disables_auto_recharge(client, monkeypatch):
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    db._conn.execute(
        "UPDATE quotas SET auto_recharge_mode=2, overage_enabled=1 WHERE user_id='u1'",
    )
    event = _fake_event("payment_intent.payment_failed", {
        "id": "pi_test_2",
        "metadata": {"user_id": "u1", "credits": "500"},
        "last_payment_error": {"message": "card_declined"},
    })
    monkeypatch.setattr(
        "tally_orchestrator.service._verify_stripe_signature",
        lambda payload, sig: event,
    )
    r = client.post(
        "/webhooks/stripe",
        content=json.dumps(event).encode(),
        headers={"stripe-signature": "t=0,v1=fake"},
    )
    assert r.status_code == 200
    row = db._conn.execute(
        "SELECT auto_recharge_mode, overage_enabled FROM quotas WHERE user_id='u1'"
    ).fetchone()
    assert row[0] == 0
    assert row[1] == 0


def test_duplicate_payment_intent_webhook_is_idempotent(client, monkeypatch):
    """Webhook retries must not double-credit."""
    import tally_orchestrator.service as svc
    db = svc.state["db"]
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    db._conn.execute(
        "INSERT INTO overage_purchases "
        "(user_id, ts, credits_purchased, cost_charged_micro_usd, kind, "
        "stripe_payment_intent_id, status) "
        "VALUES ('u1', 0, 500, 10000000, 'auto_recharge_unlimited', 'pi_test_3', 'pending')",
    )
    event = _fake_event("payment_intent.succeeded", {
        "id": "pi_test_3",
        "metadata": {"user_id": "u1", "credits": "500"},
    })
    monkeypatch.setattr(
        "tally_orchestrator.service._verify_stripe_signature",
        lambda payload, sig: event,
    )
    r1 = client.post("/webhooks/stripe", content=json.dumps(event).encode(),
                     headers={"stripe-signature": "t=0,v1=fake"})
    r2 = client.post("/webhooks/stripe", content=json.dumps(event).encode(),
                     headers={"stripe-signature": "t=0,v1=fake"})
    assert r1.status_code == 200
    assert r2.status_code == 200
    assert db.get_prepaid_balance("u1") == 500  # NOT 1000
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_stripe_webhook.py -v
```

Expected: 4 FAILs (route missing).

- [ ] **Step 3: Add webhook signature helper + route**

In `service.py` near the top imports, add a tiny helper near `b64url_no_pad` (line 323):

```python
def _verify_stripe_signature(payload: bytes, sig_header: str) -> dict:
    """Verify a Stripe webhook signature; return the parsed event.

    Raises HTTPException(400) on any failure.  Uses the official
    stripe SDK's Webhook.construct_event which validates the
    timestamp + HMAC.
    """
    secret = os.environ.get("STRIPE_WEBHOOK_SECRET", "").strip()
    if not secret:
        raise HTTPException(503, "STRIPE_WEBHOOK_SECRET not configured")
    try:
        import stripe
        return stripe.Webhook.construct_event(payload, sig_header, secret)
    except Exception as exc:
        raise HTTPException(400, f"invalid stripe signature: {exc}")
```

Then add the route handler after the `/webhooks/clerk` block:

```python
@app.post("/webhooks/stripe")
async def stripe_webhook(request: Request) -> dict:
    """Stripe → Tally webhook receiver.

    Events we act on:
      - checkout.session.completed: one-time credit purchase
      - setup_intent.succeeded: save card for auto-recharge
      - payment_intent.succeeded: auto-recharge fired successfully
      - payment_intent.payment_failed: disable auto-recharge + notify
    Other events: 200 OK, no-op.
    """
    db: Db = state["db"]
    payload = await request.body()
    sig = request.headers.get("stripe-signature") or ""
    event = _verify_stripe_signature(payload, sig)
    evt_type = event.get("type", "")
    data = (event.get("data") or {}).get("object") or {}
    metadata = data.get("metadata") or {}
    user_id = metadata.get("user_id")

    if evt_type == "checkout.session.completed":
        if not user_id:
            logger.warning("stripe webhook: checkout.session.completed missing user_id")
            return {"ok": True}
        pi_id = data.get("payment_intent")
        credits = int(metadata.get("credits", "0") or 0)
        # Idempotent: only credit if the matching overage_purchases row
        # is still 'pending' (re-deliveries get a no-op).
        cur = db._conn.execute(
            "SELECT id, credits_purchased, status FROM overage_purchases "
            "WHERE stripe_payment_intent_id=? AND user_id=?",
            (pi_id, user_id),
        ).fetchone()
        if cur and cur[2] == "pending":
            db.increment_prepaid_balance(user_id, int(cur[1]))
            db._conn.execute(
                "UPDATE overage_purchases SET status='succeeded' WHERE id=?",
                (cur[0],),
            )
            logger.info("stripe: credited %d to user=%s from %s", cur[1], user_id, pi_id)
        elif not cur and credits > 0:
            # Defensive: no pending row but we know the credit count.  Insert
            # a synthesized row + credit.  Should not happen in normal flow.
            db.increment_prepaid_balance(user_id, credits)
            db._conn.execute(
                "INSERT INTO overage_purchases "
                "(user_id, ts, credits_purchased, cost_charged_micro_usd, "
                "kind, stripe_payment_intent_id, status) "
                "VALUES (?, ?, ?, ?, 'one_time', ?, 'succeeded')",
                (user_id, time.time(), credits, credits * 20_000, pi_id),
            )
        return {"ok": True}

    if evt_type == "setup_intent.succeeded":
        if not user_id:
            return {"ok": True}
        pm = data.get("payment_method")
        customer = data.get("customer")
        db._conn.execute(
            "UPDATE quotas SET stripe_payment_method_id=?, stripe_customer_id=COALESCE(?, stripe_customer_id), "
            "updated_at=? WHERE user_id=?",
            (pm, customer, time.time(), user_id),
        )
        logger.info("stripe: saved payment_method=%s for user=%s", pm, user_id)
        return {"ok": True}

    if evt_type == "payment_intent.succeeded":
        if not user_id:
            return {"ok": True}
        pi_id = data.get("id")
        cur = db._conn.execute(
            "SELECT id, credits_purchased, status FROM overage_purchases "
            "WHERE stripe_payment_intent_id=? AND user_id=?",
            (pi_id, user_id),
        ).fetchone()
        if cur and cur[2] == "pending":
            db.increment_prepaid_balance(user_id, int(cur[1]))
            db._conn.execute(
                "UPDATE overage_purchases SET status='succeeded' WHERE id=?",
                (cur[0],),
            )
            logger.info("stripe: payment_intent.succeeded credited %d to %s", cur[1], user_id)
        return {"ok": True}

    if evt_type == "payment_intent.payment_failed":
        if not user_id:
            return {"ok": True}
        reason = (data.get("last_payment_error") or {}).get("message", "unknown")
        pi_id = data.get("id")
        db._conn.execute(
            "UPDATE overage_purchases SET status='failed', failure_reason=? "
            "WHERE stripe_payment_intent_id=? AND user_id=?",
            (reason, pi_id, user_id),
        )
        # Disable auto-recharge so the user isn't bombarded with
        # repeated failures.  They re-enable from the billing screen.
        db._conn.execute(
            "UPDATE quotas SET auto_recharge_mode=0, overage_enabled=0, updated_at=? "
            "WHERE user_id=?",
            (time.time(), user_id),
        )
        logger.warning(
            "stripe: payment_failed user=%s reason=%s; auto-recharge disabled",
            user_id, reason,
        )
        # Sprint 46: emit a notification.  Best-effort.
        try:
            from .notifications import emit_notification
            await emit_notification(
                db, user_id,
                kind="auto_recharge_failed",
                severity="error",
                payload={"reason": reason},
            )
        except Exception as exc:
            logger.warning("emit_notification raised: %s", exc)
        return {"ok": True}

    logger.debug("stripe: unhandled event type %s", evt_type)
    return {"ok": True}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_stripe_webhook.py -v
```

Expected: 4 PASS (one will skip / fail until A14 lands `emit_notification`; if so, comment out the `emit_notification` call temporarily and retry, then restore in A14).

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_stripe_webhook.py
git commit -m "[s46] /webhooks/stripe: checkout / setup / payment_intent handlers + idempotency"
```

### Task A14: `notifications.py` — rule eval + push fan-out

**Files:**
- Create: `services/orchestrator/tally_orchestrator/notifications.py`
- Create: `services/orchestrator/tests/test_notification_rules.py`

- [ ] **Step 1: Write the failing tests**

Create `services/orchestrator/tests/test_notification_rules.py`:

```python
"""Sprint 46: notification rule evaluation."""
import json
import pytest
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
        cost_micro_usd=8_000_000,  # 800 credits
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


def test_insert_notification_and_list(db):
    db.get_or_create_quota("u1", plan_hint="pro_beta")
    nid = insert_notification(db, "u1", kind="test", severity="info", payload={"k": "v"})
    out = list_notifications(db, "u1", limit=10)
    assert len(out) == 1
    assert out[0]["id"] == nid
    assert json.loads(out[0]["payload_json"]) == {"k": "v"}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_notification_rules.py -v
```

Expected: 5 FAILs (module doesn't exist).

- [ ] **Step 3: Write `notifications.py`**

```python
# services/orchestrator/tally_orchestrator/notifications.py
"""Sprint 46: notification rules + push fan-out.

Doorbell pattern (spec §"Doorbell pattern"): push payloads never
carry content.  We send empty signals; the client fetches actual
notification rows over authenticated TLS.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import random
import time
from typing import TYPE_CHECKING

import httpx

if TYPE_CHECKING:
    from .service import Db

logger = logging.getLogger("tally.notifications")

# Active WebSockets keyed by user_id → list of WebSocket instances.
# Lives on the service module to share with the orchestrator and HTTP
# routes; populated by /ws/notifications.
_ACTIVE_WS: dict[str, list] = {}


def register_websocket(user_id: str, ws) -> None:
    _ACTIVE_WS.setdefault(user_id, []).append(ws)


def unregister_websocket(user_id: str, ws) -> None:
    lst = _ACTIVE_WS.get(user_id) or []
    try:
        lst.remove(ws)
    except ValueError:
        pass
    if not lst and user_id in _ACTIVE_WS:
        del _ACTIVE_WS[user_id]


def active_websockets_for_user(user_id: str) -> list:
    return list(_ACTIVE_WS.get(user_id) or [])


def insert_notification(
    db: "Db",
    user_id: str,
    *,
    kind: str,
    severity: str = "info",
    payload: dict | None = None,
    rule_id: int | None = None,
) -> int:
    """Insert one notification row; returns its id."""
    cur = db._conn.execute(
        "INSERT INTO notifications "
        "(user_id, rule_id, kind, severity, payload_json, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (user_id, rule_id, kind, severity, json.dumps(payload or {}), time.time()),
    )
    return cur.lastrowid


def list_notifications(
    db: "Db", user_id: str, *, limit: int = 50, since_id: int | None = None,
    include_dismissed: bool = False,
) -> list[dict]:
    where = ["user_id=?"]
    params: list = [user_id]
    if since_id is not None:
        where.append("id > ?")
        params.append(since_id)
    if not include_dismissed:
        where.append("dismissed_at IS NULL")
    params.append(limit)
    rows = db._conn.execute(
        f"SELECT id, user_id, rule_id, kind, severity, payload_json, "
        f"created_at, dismissed_at FROM notifications "
        f"WHERE {' AND '.join(where)} ORDER BY created_at DESC LIMIT ?",
        params,
    ).fetchall()
    return [
        {
            "id": r[0], "user_id": r[1], "rule_id": r[2], "kind": r[3],
            "severity": r[4], "payload_json": r[5],
            "created_at": r[6], "dismissed_at": r[7],
        }
        for r in rows
    ]


def dismiss_notification(db: "Db", user_id: str, notification_id: int) -> bool:
    cur = db._conn.execute(
        "UPDATE notifications SET dismissed_at=? "
        "WHERE id=? AND user_id=? AND dismissed_at IS NULL",
        (time.time(), notification_id, user_id),
    )
    return cur.rowcount > 0


def seed_default_rules(db: "Db", user_id: str, *, plan: str) -> None:
    """Spec §"Notification rules": default rules on first paid upgrade.

    Mode-3 users get NO defaults + a soft nudge.  Free tier also no
    defaults (their entire allotment is so small that 80% alerts are
    noise)."""
    if plan == "free":
        return
    quota = db.get_or_create_quota(user_id)
    if int(quota.get("auto_recharge_mode") or 0) == 3:
        return
    # Idempotent — skip if any period_pct rule exists already.
    existing = db._conn.execute(
        "SELECT COUNT(*) FROM notification_rules WHERE user_id=? AND kind='period_pct'",
        (user_id,),
    ).fetchone()
    if int(existing[0]) > 0:
        return
    now = time.time()
    for threshold in (80, 100):
        db._conn.execute(
            "INSERT INTO notification_rules "
            "(user_id, kind, threshold, enabled, created_at) "
            "VALUES (?, 'period_pct', ?, 1, ?)",
            (user_id, threshold, now),
        )


def evaluate_rules_for_cost_event(db: "Db", user_id: str) -> list[dict]:
    """After a cost event lands, evaluate all enabled rules for this
    user.  Returns the list of notifications inserted.

    Each rule fires AT MOST ONCE per period (recorded in
    `last_fired_at`).  Period rollover (Sprint 44 sweeper) resets it.
    """
    from .service import QUOTA_PLANS
    quota = db.get_or_create_quota(user_id)
    plan = QUOTA_PLANS.get(quota["plan"], QUOTA_PLANS["free"])
    used = db.credits_used_this_period(user_id, quota["period_start"])
    included = max(1, int(plan["included_credits"]))
    pct = (used * 100) // included
    fired: list[dict] = []
    rules = db._conn.execute(
        "SELECT id, kind, threshold, last_fired_at FROM notification_rules "
        "WHERE user_id=? AND enabled=1",
        (user_id,),
    ).fetchall()
    for rid, kind, threshold, last_fired_at in rules:
        if last_fired_at is not None and last_fired_at >= quota["period_start"]:
            continue  # already fired this period
        if kind == "period_pct" and pct >= int(threshold):
            nid = insert_notification(
                db, user_id,
                kind="period_pct_crossed",
                severity="warning" if int(threshold) >= 100 else "info",
                payload={"threshold_pct": int(threshold), "used_credits": used,
                         "included_credits": included},
                rule_id=rid,
            )
            db._conn.execute(
                "UPDATE notification_rules SET last_fired_at=? WHERE id=?",
                (time.time(), rid),
            )
            fired.append({"id": nid, "kind": "period_pct_crossed",
                          "threshold": int(threshold)})
        elif kind == "daily_amount":
            day_used = db.credits_used_in_window(user_id, time.time() - 86400)
            if day_used >= int(threshold):
                nid = insert_notification(
                    db, user_id, kind="daily_amount_reached",
                    severity="info",
                    payload={"threshold": int(threshold), "used": day_used},
                    rule_id=rid,
                )
                db._conn.execute(
                    "UPDATE notification_rules SET last_fired_at=? WHERE id=?",
                    (time.time(), rid),
                )
                fired.append({"id": nid, "kind": "daily_amount_reached"})
        elif kind == "weekly_amount":
            week_used = db.credits_used_in_window(user_id, time.time() - 7 * 86400)
            if week_used >= int(threshold):
                nid = insert_notification(
                    db, user_id, kind="weekly_amount_reached",
                    severity="info",
                    payload={"threshold": int(threshold), "used": week_used},
                    rule_id=rid,
                )
                db._conn.execute(
                    "UPDATE notification_rules SET last_fired_at=? WHERE id=?",
                    (time.time(), rid),
                )
                fired.append({"id": nid, "kind": "weekly_amount_reached"})
    return fired


async def fan_out_push(db: "Db", user_id: str, notification_id: int) -> None:
    """Doorbell pattern (spec §"Notification delivery"):

      1. Notification already in DB (caller's responsibility).
      2. Random 0-5s jitter (timing-correlation defense).
      3. Broadcast `{"type":"new_notification","id":N}` to active WS.
      4. For enrolled devices WITHOUT an active WS, POST empty body
         to the UnifiedPush endpoint.  Desktop devices are local-
         only; nothing to send.
    """
    max_jitter = float(os.environ.get("TALLY_PUSH_JITTER_MAX_S", "5"))
    await asyncio.sleep(random.uniform(0, max_jitter))
    # WS broadcast
    for ws in active_websockets_for_user(user_id):
        try:
            await ws.send_json({"type": "new_notification", "id": notification_id})
        except Exception as exc:
            logger.warning("ws send failed for user=%s: %s", user_id, exc)
    # UnifiedPush wake-up
    devices = db._conn.execute(
        "SELECT provider, endpoint_url FROM push_devices WHERE user_id=? AND enabled=1",
        (user_id,),
    ).fetchall()
    for provider, endpoint in devices:
        if provider == "unifiedpush" and endpoint:
            try:
                async with httpx.AsyncClient(timeout=5.0) as cli:
                    await cli.post(endpoint, content=b"")
                db._conn.execute(
                    "UPDATE push_devices SET last_seen_at=? WHERE user_id=? AND endpoint_url=?",
                    (time.time(), user_id, endpoint),
                )
            except Exception as exc:
                logger.warning("unifiedpush POST failed for %s: %s", endpoint, exc)
        # desktop_local: no wake-up; client polls or holds WS open.


async def emit_notification(
    db: "Db", user_id: str, *, kind: str, severity: str = "info",
    payload: dict | None = None, rule_id: int | None = None,
) -> int:
    """Insert + fan-out in one call.  Schedules fan-out on the event
    loop; doesn't block.  Returns the notification id."""
    nid = insert_notification(
        db, user_id, kind=kind, severity=severity, payload=payload, rule_id=rule_id,
    )
    asyncio.create_task(fan_out_push(db, user_id, nid))
    return nid
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_notification_rules.py -v
```

Expected: 5 PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/notifications.py services/orchestrator/tests/test_notification_rules.py
git commit -m "[s46] notifications.py: rule eval + insert + fan-out (doorbell + jitter)"
```


### Task A15: Notification CRUD + push device + rules endpoints

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — add ~10 routes near `/billing/credits`
- Create: `services/orchestrator/tests/test_notifications_routes.py`

- [ ] **Step 1: Write the failing tests**

Create `services/orchestrator/tests/test_notifications_routes.py`:

```python
"""Sprint 46: REST endpoints for notifications + rules + push devices."""
import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch, tmp_db_path):
    monkeypatch.setenv("TALLY_DB_PATH", tmp_db_path)
    monkeypatch.setenv("TALLY_BEARER_TOKEN", "test-token")
    monkeypatch.setenv("TALLY_TEST_MODE", "1")
    import importlib, tally_orchestrator.service as svc
    importlib.reload(svc)
    svc.state["pool_ready"] = True
    from tally_orchestrator.clerk_auth import ClerkUser
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="u1", source="clerk", plan="pro_beta", email="u1@x.com",
    )
    yield TestClient(svc.app)
    svc.app.dependency_overrides.clear()


def test_get_notifications_empty(client):
    r = client.get("/notifications")
    assert r.status_code == 200
    assert r.json() == {"notifications": [], "next_since_id": 0}


def test_post_dismiss_notification(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.notifications import insert_notification
    nid = insert_notification(svc.state["db"], "u1", kind="test")
    r = client.post(f"/notifications/{nid}/dismiss")
    assert r.status_code == 200
    r2 = client.get("/notifications")
    assert r2.json()["notifications"] == []


def test_post_notification_rule(client):
    r = client.post("/notification_rules", json={"kind": "period_pct", "threshold": 50})
    assert r.status_code == 200
    body = r.json()
    assert body["kind"] == "period_pct"
    assert body["threshold"] == 50


def test_patch_notification_rule(client):
    r = client.post("/notification_rules", json={"kind": "daily_amount", "threshold": 100})
    rid = r.json()["id"]
    r2 = client.patch(f"/notification_rules/{rid}", json={"threshold": 200, "enabled": False})
    assert r2.status_code == 200
    assert r2.json()["threshold"] == 200
    assert r2.json()["enabled"] is False


def test_delete_notification_rule(client):
    r = client.post("/notification_rules", json={"kind": "daily_amount", "threshold": 100})
    rid = r.json()["id"]
    r2 = client.delete(f"/notification_rules/{rid}")
    assert r2.status_code == 200
    r3 = client.get("/notification_rules")
    assert all(rule["id"] != rid for rule in r3.json()["rules"])


def test_post_push_device_unifiedpush(client):
    r = client.post("/push/devices", json={
        "provider": "unifiedpush",
        "endpoint_url": "https://distributor.example/upo/abc",
        "label": "Phone",
        "platform": "android",
    })
    assert r.status_code == 200
    assert r.json()["provider"] == "unifiedpush"


def test_post_push_device_desktop_local(client):
    r = client.post("/push/devices", json={"provider": "desktop_local", "label": "Linux laptop"})
    assert r.status_code == 200
    assert r.json()["endpoint_url"] is None


def test_post_push_device_rejects_unknown_provider(client):
    r = client.post("/push/devices", json={"provider": "fcm", "endpoint_url": "x"})
    assert r.status_code == 400


def test_delete_push_device(client):
    r = client.post("/push/devices", json={"provider": "desktop_local", "label": "x"})
    did = r.json()["id"]
    r2 = client.delete(f"/push/devices/{did}")
    assert r2.status_code == 200
    r3 = client.get("/push/devices")
    assert all(d["id"] != did for d in r3.json()["devices"])
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_notifications_routes.py -v
```

Expected: 9 FAILs.

- [ ] **Step 3: Add Pydantic models near other request models in `service.py`**

```python
class NotificationRuleRequest(BaseModel):
    kind: str  # 'period_pct' | 'daily_amount' | 'weekly_amount' | 'per_task_amount' | 'auto_recharge_monthly_pct'
    threshold: int
    enabled: bool = True


class NotificationRulePatchRequest(BaseModel):
    threshold: int | None = None
    enabled: bool | None = None


class PushDeviceRequest(BaseModel):
    provider: str  # 'unifiedpush' | 'desktop_local'
    endpoint_url: str | None = None
    label: str | None = None
    platform: str | None = None
```

- [ ] **Step 4: Add routes near `/billing/credits`**

```python
_NOTIFICATION_RULE_KINDS = {
    "period_pct", "daily_amount", "weekly_amount",
    "per_task_amount", "auto_recharge_monthly_pct",
}
_PUSH_PROVIDERS = {"unifiedpush", "desktop_local"}


@app.get("/notifications")
async def get_notifications(
    limit: int = 50,
    since_id: int | None = None,
    user: ClerkUser = Depends(require_user),
) -> dict:
    from .notifications import list_notifications
    db: Db = state["db"]
    items = list_notifications(db, user.id, limit=limit, since_id=since_id)
    next_since = max((n["id"] for n in items), default=since_id or 0)
    return {"notifications": items, "next_since_id": next_since}


@app.post("/notifications/{notification_id}/dismiss")
async def post_dismiss_notification(
    notification_id: int,
    user: ClerkUser = Depends(require_user),
) -> dict:
    from .notifications import dismiss_notification
    db: Db = state["db"]
    if not dismiss_notification(db, user.id, notification_id):
        raise HTTPException(404, "notification not found")
    return {"ok": True}


@app.get("/notification_rules")
async def get_notification_rules(user: ClerkUser = Depends(require_user)) -> dict:
    db: Db = state["db"]
    rows = db._conn.execute(
        "SELECT id, kind, threshold, enabled, last_fired_at, created_at "
        "FROM notification_rules WHERE user_id=? ORDER BY created_at",
        (user.id,),
    ).fetchall()
    rules = [
        {"id": r[0], "kind": r[1], "threshold": r[2],
         "enabled": bool(r[3]), "last_fired_at": r[4], "created_at": r[5]}
        for r in rows
    ]
    return {"rules": rules}


@app.post("/notification_rules")
async def post_notification_rule(
    body: NotificationRuleRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    if body.kind not in _NOTIFICATION_RULE_KINDS:
        raise HTTPException(400, f"unknown kind: {body.kind}")
    if body.threshold <= 0:
        raise HTTPException(400, "threshold must be > 0")
    db: Db = state["db"]
    cur = db._conn.execute(
        "INSERT INTO notification_rules "
        "(user_id, kind, threshold, enabled, created_at) "
        "VALUES (?, ?, ?, ?, ?)",
        (user.id, body.kind, body.threshold, int(body.enabled), time.time()),
    )
    return {
        "id": cur.lastrowid, "kind": body.kind, "threshold": body.threshold,
        "enabled": body.enabled,
    }


@app.patch("/notification_rules/{rule_id}")
async def patch_notification_rule(
    rule_id: int,
    body: NotificationRulePatchRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    db: Db = state["db"]
    fields: list[str] = []
    values: list = []
    if body.threshold is not None:
        if body.threshold <= 0:
            raise HTTPException(400, "threshold must be > 0")
        fields.append("threshold=?")
        values.append(body.threshold)
    if body.enabled is not None:
        fields.append("enabled=?")
        values.append(int(body.enabled))
    if not fields:
        raise HTTPException(400, "no fields to update")
    values += [rule_id, user.id]
    cur = db._conn.execute(
        f"UPDATE notification_rules SET {', '.join(fields)} WHERE id=? AND user_id=?",
        values,
    )
    if cur.rowcount == 0:
        raise HTTPException(404, "rule not found")
    row = db._conn.execute(
        "SELECT id, kind, threshold, enabled, last_fired_at, created_at "
        "FROM notification_rules WHERE id=? AND user_id=?",
        (rule_id, user.id),
    ).fetchone()
    return {
        "id": row[0], "kind": row[1], "threshold": row[2],
        "enabled": bool(row[3]), "last_fired_at": row[4], "created_at": row[5],
    }


@app.delete("/notification_rules/{rule_id}")
async def delete_notification_rule(
    rule_id: int,
    user: ClerkUser = Depends(require_user),
) -> dict:
    db: Db = state["db"]
    cur = db._conn.execute(
        "DELETE FROM notification_rules WHERE id=? AND user_id=?",
        (rule_id, user.id),
    )
    if cur.rowcount == 0:
        raise HTTPException(404, "rule not found")
    return {"ok": True}


@app.get("/push/devices")
async def get_push_devices(user: ClerkUser = Depends(require_user)) -> dict:
    db: Db = state["db"]
    rows = db._conn.execute(
        "SELECT id, provider, endpoint_url, label, platform, enabled, last_seen_at, created_at "
        "FROM push_devices WHERE user_id=? ORDER BY created_at DESC",
        (user.id,),
    ).fetchall()
    devices = [
        {"id": r[0], "provider": r[1], "endpoint_url": r[2], "label": r[3],
         "platform": r[4], "enabled": bool(r[5]), "last_seen_at": r[6],
         "created_at": r[7]}
        for r in rows
    ]
    return {"devices": devices}


@app.post("/push/devices")
async def post_push_device(
    body: PushDeviceRequest,
    user: ClerkUser = Depends(require_user),
) -> dict:
    if body.provider not in _PUSH_PROVIDERS:
        raise HTTPException(400, f"unknown provider: {body.provider}")
    if body.provider == "unifiedpush" and not body.endpoint_url:
        raise HTTPException(400, "unifiedpush requires endpoint_url")
    db: Db = state["db"]
    cur = db._conn.execute(
        "INSERT INTO push_devices "
        "(user_id, provider, endpoint_url, label, platform, enabled, created_at) "
        "VALUES (?, ?, ?, ?, ?, 1, ?)",
        (user.id, body.provider, body.endpoint_url, body.label, body.platform, time.time()),
    )
    return {
        "id": cur.lastrowid, "provider": body.provider,
        "endpoint_url": body.endpoint_url, "label": body.label,
        "platform": body.platform, "enabled": True,
    }


@app.delete("/push/devices/{device_id}")
async def delete_push_device(
    device_id: int,
    user: ClerkUser = Depends(require_user),
) -> dict:
    db: Db = state["db"]
    cur = db._conn.execute(
        "DELETE FROM push_devices WHERE id=? AND user_id=?",
        (device_id, user.id),
    )
    if cur.rowcount == 0:
        raise HTTPException(404, "device not found")
    return {"ok": True}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_notifications_routes.py -v
```

Expected: 9 PASS.

- [ ] **Step 6: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_notifications_routes.py
git commit -m "[s46] /notifications, /notification_rules, /push/devices CRUD endpoints"
```

### Task A16: Alert evaluation hook on cost event insertion (Checkpoint 7)

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — `Db.record_cost_event` + orchestrator agent-complete path
- Create: `services/orchestrator/tests/test_alert_hook.py`

- [ ] **Step 1: Write the failing test**

Create `services/orchestrator/tests/test_alert_hook.py`:

```python
"""Sprint 46: Checkpoint 7 — alert evaluation fires after cost events."""
import pytest


@pytest.mark.asyncio
async def test_emit_notification_fires_when_threshold_crossed(db, monkeypatch):
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
```

Add to `pyproject.toml` `[tool.pytest.ini_options]` an `asyncio_mode = "auto"` line:

```toml
[tool.pytest.ini_options]
asyncio_mode = "auto"
```

- [ ] **Step 2: Run test to verify it fails initially or passes if A14 is sufficient**

```bash
cd services/orchestrator && uv run pytest tests/test_alert_hook.py -v
```

Expected: PASS (A14 already provides the evaluation primitives; this test confirms the integration).

- [ ] **Step 3: Wire rule evaluation into the orchestrator's agent-complete path**

In `service.py` find the orchestrator's per-agent cost-recording site (around the worker result handler — search for `record_cost_event` calls outside the architect path). Right after each such call, insert:

```python
        # Sprint 46: Checkpoint 7 — fire alerts on cost events.  Best-
        # effort: never let an alert failure crash the dispatch loop.
        try:
            from .notifications import evaluate_rules_for_cost_event, fan_out_push
            fired = evaluate_rules_for_cost_event(self.db, user_id)
            for f in fired:
                asyncio.create_task(fan_out_push(self.db, user_id, f["id"]))
        except Exception as exc:
            logger.warning("alert evaluation raised: %s", exc)
```

Locate the architect cost recorder in POST /tasks (around line 3653, `_record_architect_cost`) and append the same block right after `db.record_cost_event(...)` there. Do NOT make `_record_architect_cost` async (it's called from a thread); use `asyncio.get_event_loop().call_soon_threadsafe` or simply enqueue via a thread-safe queue if needed. Simplest: just evaluate synchronously and let `fan_out_push` schedule itself via the running loop:

```python
            try:
                from .notifications import evaluate_rules_for_cost_event
                from asyncio import get_event_loop
                fired = evaluate_rules_for_cost_event(db, user.id)
                loop = get_event_loop()
                for f in fired:
                    from .notifications import fan_out_push
                    loop.call_soon_threadsafe(
                        asyncio.create_task,
                        fan_out_push(db, user.id, f["id"]),
                    )
            except Exception as exc:
                logger.warning("alert evaluation raised: %s", exc)
```

- [ ] **Step 4: Seed default rules on first upgrade**

In `service.py`'s Clerk webhook handler at the `set_user_plan` site (search for `set_user_plan(`), after the plan update, call:

```python
        from .notifications import seed_default_rules
        try:
            seed_default_rules(state["db"], user_id, plan=evt.plan)
        except Exception as exc:
            logger.warning("seed_default_rules raised: %s", exc)
```

Also seed on JWT-claim sync. In `get_or_create_quota`, after upgrading the plan via plan_hint (the `if plan_hint and not is_admin and plan_hint != stored_plan` branch in `service.py:1526`), call seed_default_rules.

To avoid a circular import, defer the import inline:

```python
        if plan_hint != "free":
            try:
                from .notifications import seed_default_rules
                seed_default_rules(self, user_id, plan=plan_hint)
            except Exception:
                pass
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_alert_hook.py tests/test_notification_rules.py -v
```

Expected: 6 PASS (1 alert hook + 5 rule eval).

- [ ] **Step 6: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tests/test_alert_hook.py services/orchestrator/pyproject.toml
git commit -m "[s46] Checkpoint 7: evaluate notification rules on every cost event"
```

### Task A17: `/ws/notifications` WebSocket endpoint

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/service.py` — add WebSocket route
- Create: `services/orchestrator/tests/test_websocket_notifications.py`

- [ ] **Step 1: Write the failing test**

Create `services/orchestrator/tests/test_websocket_notifications.py`:

```python
"""Sprint 46: /ws/notifications endpoint."""
import json
import pytest
from fastapi.testclient import TestClient


@pytest.fixture
def client(monkeypatch, tmp_db_path):
    monkeypatch.setenv("TALLY_DB_PATH", tmp_db_path)
    monkeypatch.setenv("TALLY_BEARER_TOKEN", "test-token")
    monkeypatch.setenv("TALLY_TEST_MODE", "1")
    import importlib, tally_orchestrator.service as svc
    importlib.reload(svc)
    svc.state["pool_ready"] = True
    from tally_orchestrator.clerk_auth import ClerkUser
    svc.app.dependency_overrides[svc.require_user] = lambda: ClerkUser(
        id="u1", source="clerk", plan="pro_beta", email="u1@x.com",
    )
    yield TestClient(svc.app)
    svc.app.dependency_overrides.clear()


def test_websocket_handshake_accepts_with_token(client):
    with client.websocket_connect("/ws/notifications?token=test-token") as ws:
        # Server should send a hello frame
        msg = ws.receive_json()
        assert msg["type"] == "hello"


def test_websocket_rejects_without_token(client):
    with pytest.raises(Exception):
        with client.websocket_connect("/ws/notifications"):
            pass


@pytest.mark.asyncio
async def test_websocket_receives_notification_signal(client):
    import tally_orchestrator.service as svc
    from tally_orchestrator.notifications import insert_notification, fan_out_push
    with client.websocket_connect("/ws/notifications?token=test-token") as ws:
        ws.receive_json()  # discard hello
        nid = insert_notification(svc.state["db"], "u1", kind="test")
        # Force jitter to 0 for predictable test
        import os
        os.environ["TALLY_PUSH_JITTER_MAX_S"] = "0"
        import asyncio
        await fan_out_push(svc.state["db"], "u1", nid)
        msg = ws.receive_json()
        assert msg["type"] == "new_notification"
        assert msg["id"] == nid
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd services/orchestrator && uv run pytest tests/test_websocket_notifications.py -v
```

Expected: 3 FAILs.

- [ ] **Step 3: Add the WebSocket route**

In `service.py` near the SSE `/tasks/{task_id}/stream` route, add:

```python
from fastapi import WebSocket, WebSocketDisconnect


async def _ws_authenticate(websocket: WebSocket) -> str:
    """Accept either ?token=<bearer> for admin or ?token=<clerk-jwt>
    for end users.  Returns the resolved user_id or 4401-closes the
    socket.
    """
    token = websocket.query_params.get("token", "")
    if not token:
        await websocket.close(code=4401, reason="missing token")
        raise WebSocketDisconnect(code=4401)
    bearer = os.environ.get("TALLY_BEARER_TOKEN", "").strip()
    if bearer and token == bearer:
        return "admin"
    # Try Clerk JWT path
    try:
        from .clerk_auth import _verify_session_token
        claims = _verify_session_token(token)
        return claims.get("sub") or "anon"
    except Exception:
        await websocket.close(code=4401, reason="invalid token")
        raise WebSocketDisconnect(code=4401)


@app.websocket("/ws/notifications")
async def ws_notifications(websocket: WebSocket) -> None:
    """Sprint 46: live notification feed.

    Client subscribes; server sends `{"type":"hello"}` on accept,
    then `{"type":"new_notification","id":int}` for each notification.
    Server also accepts client→server `{"type":"ping"}` keepalives
    and replies `{"type":"pong"}`.
    """
    await websocket.accept()
    user_id = await _ws_authenticate(websocket)
    from .notifications import register_websocket, unregister_websocket
    register_websocket(user_id, websocket)
    await websocket.send_json({"type": "hello", "user_id": user_id})
    try:
        while True:
            msg = await websocket.receive_json()
            if msg.get("type") == "ping":
                await websocket.send_json({"type": "pong"})
    except WebSocketDisconnect:
        pass
    finally:
        unregister_websocket(user_id, websocket)
```

If `_verify_session_token` doesn't exist as a public helper in `clerk_auth.py`, add a tiny wrapper there:

```python
# clerk_auth.py — add at the bottom
def _verify_session_token(token: str) -> dict:
    """Public alias for the same JWT verification used by require_user."""
    return _decode_clerk_jwt(token)  # whatever the internal name is
```

(Inspect `clerk_auth.py` and reuse the existing decoder; the name may differ.)

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd services/orchestrator && uv run pytest tests/test_websocket_notifications.py -v
```

Expected: 3 PASS.

- [ ] **Step 5: Commit**

```bash
git add services/orchestrator/tally_orchestrator/service.py services/orchestrator/tally_orchestrator/clerk_auth.py services/orchestrator/tests/test_websocket_notifications.py
git commit -m "[s46] /ws/notifications: authenticated WebSocket for live notifications"
```

### Task A18: Worker `usage_tokens` + `model` emission

**Files:**
- Modify: worker code in `~/Projects/pronoic/tally-workers/` (the Rust worker; exact file determined by grep below)
- Create: integration test in `tally-workers/integration-tests/`

- [ ] **Step 1: Locate the worker's result-event emission code**

```bash
cd ~/Projects/pronoic/tally-workers && grep -rn "result_event\|usage_tokens\|completion_tokens" --include="*.rs" | head -20
```

Result identifies the file (likely `tally-worker/src/result.rs` or `tally-worker/src/agent.rs`).

- [ ] **Step 2: Write a failing test (integration-tests crate)**

Add a test that asserts the result event payload contains `usage_tokens` and `model` keys. Pattern follows existing `tally-workers/integration-tests/` tests.

- [ ] **Step 3: Modify worker code**

In the identified file, the result event constructor should include `usage_tokens: usize` (sum of `prompt_tokens + completion_tokens` from each LLM call inside the agent's run) and `model: String` (the model the agent actually used, post-allowlist). Emit BOTH fields in the serialized result. Keep backwards compatibility: orchestrator falls back to 0/empty if the worker is older.

- [ ] **Step 4: Run worker integration test**

```bash
cd ~/Projects/pronoic/tally-workers && cargo test -p tally-integration-tests usage_tokens_in_result
```

Expected: PASS.

- [ ] **Step 5: Update orchestrator to consume `usage_tokens` + `model` in agent results**

In `service.py` find the orchestrator's agent-result-handler (the function that processes worker result events; the same site where the architect cost recorder was set up). It already calls `record_cost_event` for the architect; extend it for agent results:

```python
                # Sprint 46: worker now emits usage_tokens + model; capture
                # them.  Fallback to estimate_team_cost_credits-style
                # heuristic if the worker is older and doesn't send them.
                usage_tokens = int(result.get("usage_tokens") or 0)
                worker_model = result.get("model") or target_agent.get("model") or ""
                if usage_tokens > 0 and worker_model:
                    # Split heuristically 80/20 prompt/completion if the
                    # worker doesn't break it down — Red Pill exposes both
                    # but most workers report the sum only.
                    prompt = int(usage_tokens * 0.8)
                    completion = usage_tokens - prompt
                    cost = compute_cost_micro_usd(worker_model, prompt, completion)
                    self.db.record_cost_event(
                        user_id=task.get("user_id") or "legacy-admin",
                        kind="agent",
                        model=worker_model,
                        prompt_tokens=prompt,
                        completion_tokens=completion,
                        total_tokens=usage_tokens,
                        cost_micro_usd=cost,
                        task_id=task_id,
                        agent_idx=target_agent.get("agent_idx"),
                    )
                    # Sprint 46 Checkpoint 6 — mid-run period cap +
                    # auto-recharge.  After this cost event, if the
                    # user's period pool just went negative AND they
                    # have Mode 2/3 auto-recharge with overage enabled,
                    # try a top-up.  If they don't (or top-up fails),
                    # abort the task with period_cap_reached.
                    uid = task.get("user_id") or "legacy-admin"
                    try:
                        avail = self.db.credits_available(uid)
                        if avail <= 0:
                            quota = self.db.get_or_create_quota(uid)
                            mode = int(quota.get("auto_recharge_mode") or 0)
                            handled = False
                            if mode == 3:
                                try:
                                    from .stripe_direct import trigger_auto_recharge_unlimited
                                    await trigger_auto_recharge_unlimited(self.db, uid)
                                    handled = True
                                except Exception as rex:
                                    logger.warning(
                                        "mid-run auto-recharge (mode 3) failed for %s: %s",
                                        uid, rex,
                                    )
                            elif mode == 2:
                                try:
                                    from .stripe_direct import trigger_auto_recharge_capped
                                    if await trigger_auto_recharge_capped(self.db, uid):
                                        handled = True
                                except Exception as rex:
                                    logger.warning(
                                        "mid-run auto-recharge (mode 2) failed for %s: %s",
                                        uid, rex,
                                    )
                            if not handled:
                                self.db.mark_failed(
                                    task_id,
                                    "period cap reached: no credits available",
                                )
                                self._task_artifacts.pop(task_id, None)
                                await self._publish_status(task_id, "aborted_cost_cap", {
                                    "reason": "period_cap_reached",
                                    "available_credits": 0,
                                })
                                logger.info(
                                    "task %s aborted: period cap reached for user=%s",
                                    task_id[:8], uid,
                                )
                                return
                    except Exception as exc:
                        logger.warning(
                            "period cap check failed for task %s: %s",
                            task_id[:8], exc,
                        )
                    # Fire alerts on this cost event (Checkpoint 7)
                    try:
                        from .notifications import evaluate_rules_for_cost_event, fan_out_push
                        fired = evaluate_rules_for_cost_event(self.db, uid)
                        for f in fired:
                            asyncio.create_task(fan_out_push(self.db, uid, f["id"]))
                    except Exception as exc:
                        logger.warning("alert eval (agent) raised: %s", exc)
```

- [ ] **Step 6: Commit (per repo)**

```bash
cd ~/Projects/pronoic/tally-workers
git add tally-worker/src/<file> integration-tests/src/<file>
git commit -m "[s46] emit usage_tokens + model in agent result events"

cd ~/Projects/pronoic/tally-coding
git add services/orchestrator/tally_orchestrator/service.py
git commit -m "[s46] record agent cost_events from worker-supplied usage_tokens + model"
```

### Task A19: End-of-Phase-A workspace smoke test

**Files:**
- None to write; verify all tests pass.

- [ ] **Step 1: Run the full orchestrator test suite**

```bash
cd services/orchestrator && uv run pytest tests/ -v
```

Expected: all PASS (~50 tests total across credits, gates, mid-run cap, stripe, webhooks, notifications, rules, routes, websocket, alert hook, schema, architect allowlist, cost estimate).

- [ ] **Step 2: Static type check**

```bash
cd services/orchestrator && uv run python -m mypy tally_orchestrator/ --ignore-missing-imports 2>&1 | tail -20
```

Expected: no errors (or a small set of pre-existing baseline errors that the new code doesn't add to).

- [ ] **Step 3: Start the server locally**

```bash
cd services/orchestrator && TALLY_DB_PATH=/tmp/s46-smoke.db \
  TALLY_BEARER_TOKEN=smoke-token TALLY_REDPILL_KEY="" TALLY_TEST_MODE=1 \
  uv run uvicorn tally_orchestrator.service:app --port 8118 &
```

- [ ] **Step 4: Curl smoke**

```bash
curl -s -H "Authorization: Bearer smoke-token" http://localhost:8118/billing/credits | jq .
# Should show plan, included_credits, used_credits, available_credits

curl -s -H "Authorization: Bearer smoke-token" http://localhost:8118/billing/caps | jq .

curl -s -X POST -H "Authorization: Bearer smoke-token" -H "Content-Type: application/json" \
  -d '{"kind":"period_pct","threshold":50}' \
  http://localhost:8118/notification_rules | jq .

curl -s -X POST -H "Authorization: Bearer smoke-token" -H "Content-Type: application/json" \
  -d '{"provider":"desktop_local","label":"smoke-test"}' \
  http://localhost:8118/push/devices | jq .

# Tear down
kill %1
```

Expected: all four return 200 JSON; visible fields match what tests asserted.

- [ ] **Step 5: Commit a marker tag for Phase A complete**

```bash
git tag s46-phase-a-done
```


---

## Phase B — Flutter UI

13 tasks (~13h). Builds on Phase A's REST + WebSocket surface. Tests use `flutter_test` + the testing harness for HTTP mocks (no full integration test against a live server — that's covered in Phase C smoke).

### Task B1: Add pubspec deps

**Files:**
- Modify: `tally_coding_app/pubspec.yaml`

- [ ] **Step 1: Add three packages**

Append to the `dependencies:` block in `pubspec.yaml`:

```yaml
  # Sprint 46: notification + push + WebSocket
  web_socket_channel: ^3.0.0
  unifiedpush: ^5.0.0
  flutter_local_notifications: ^17.2.0
```

- [ ] **Step 2: Run pub get**

```bash
cd tally_coding_app && flutter pub get
```

Expected: `Got dependencies!` with no version conflicts.

- [ ] **Step 3: Smoke import each package**

Create `tally_coding_app/test/sprint46_deps_smoke_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
// Note: unifiedpush is Android-only; importing it on host test runner is fine
// because it's a federated plugin with web/desktop stubs.
import 'package:unifiedpush/unifiedpush.dart';

void main() {
  test('sprint 46 packages import cleanly', () {
    expect(WebSocketChannel, isNotNull);
    expect(FlutterLocalNotificationsPlugin, isNotNull);
    expect(UnifiedPush, isNotNull);
  });
}
```

- [ ] **Step 4: Run test**

```bash
cd tally_coding_app && flutter test test/sprint46_deps_smoke_test.dart
```

Expected: 1 PASS.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/pubspec.yaml tally_coding_app/pubspec.lock tally_coding_app/test/sprint46_deps_smoke_test.dart
git commit -m "[s46] flutter: web_socket_channel + unifiedpush + flutter_local_notifications"
```

### Task B2: API client extensions (api.dart)

**Files:**
- Modify: `tally_coding_app/lib/api.dart` — add ~15 methods near the existing billing block (around line 576)

- [ ] **Step 1: Write the failing widget test**

Create `tally_coding_app/test/api_credits_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tally_coding_app/api.dart';

void main() {
  test('getCreditsBalance returns plan + balance', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/billing/credits');
      return http.Response(
        '{"plan":"pro_beta","plan_label":"Pro (Beta)","is_beta":true,'
        '"period_start":0,"included_credits":1000,"used_credits":100,'
        '"available_credits":900,"prepaid_credit_balance":0,'
        '"overage_enabled":false,"auto_recharge_mode":0,'
        '"auto_recharge_block_credits":500,"auto_recharge_monthly_cap_micro_usd":null,'
        '"auto_recharge_spent_this_month_micro_usd":0,"stripe_payment_method_id":null,'
        '"spend_alert_threshold_pct":80}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = TallyApi(
      baseUrl: Uri.parse('http://test'),
      bearerProvider: () async => 'token',
      client: mock,
    );
    final out = await api.getCreditsBalance();
    expect(out['plan'], 'pro_beta');
    expect(out['available_credits'], 900);
  });

  test('postCreditsCheckout returns stripe URL', () async {
    final mock = MockClient((req) async {
      expect(req.url.path, '/billing/credits/checkout');
      return http.Response(
        '{"session_id":"cs_test","url":"https://checkout.stripe.com/cs_test"}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final api = TallyApi(
      baseUrl: Uri.parse('http://test'),
      bearerProvider: () async => 'token',
      client: mock,
    );
    final out = await api.postCreditsCheckout(credits: 500);
    expect(out['url'], startsWith('https://checkout.stripe.com/'));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd tally_coding_app && flutter test test/api_credits_test.dart
```

Expected: 2 FAILs (methods don't exist).

- [ ] **Step 3: Add the methods in api.dart**

In `tally_coding_app/lib/api.dart` near the existing billing block (after `getBillingCost`), add:

```dart
  // ── Sprint 46: credit-based billing ─────────────────────────────────────

  Future<Map<String, dynamic>> getCreditsBalance() async {
    final resp = await _http.get(
      baseUrl.resolve('/billing/credits'),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('GET /billing/credits ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<Map<String, dynamic>> getCaps() async {
    final resp = await _http.get(
      baseUrl.resolve('/billing/caps'),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('GET /billing/caps ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<Map<String, dynamic>> patchCaps({
    int? perTaskCapCredits,
    int? dailySpendCapCredits,
    int? weeklySpendCapCredits,
  }) async {
    final body = <String, dynamic>{};
    if (perTaskCapCredits != null) body['per_task_cap_credits'] = perTaskCapCredits;
    if (dailySpendCapCredits != null) body['daily_spend_cap_credits'] = dailySpendCapCredits;
    if (weeklySpendCapCredits != null) body['weekly_spend_cap_credits'] = weeklySpendCapCredits;
    final resp = await _http.patch(
      baseUrl.resolve('/billing/caps'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200) {
      throw Exception('PATCH /billing/caps ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<Map<String, dynamic>> postCreditsCheckout({
    required int credits,
    String successUrl = 'tallycoding://billing/success',
    String cancelUrl = 'tallycoding://billing/cancel',
  }) async {
    final resp = await _http.post(
      baseUrl.resolve('/billing/credits/checkout'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode({
        'credits': credits,
        'success_url': successUrl,
        'cancel_url': cancelUrl,
      }),
    );
    if (resp.statusCode != 200) {
      throw Exception('POST /billing/credits/checkout ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<Map<String, dynamic>> postAutoRechargeSetup({
    String successUrl = 'tallycoding://billing/auto-recharge/success',
    String cancelUrl = 'tallycoding://billing/auto-recharge/cancel',
  }) async {
    final resp = await _http.post(
      baseUrl.resolve('/billing/auto-recharge/setup'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode({'success_url': successUrl, 'cancel_url': cancelUrl}),
    );
    if (resp.statusCode != 200) {
      throw Exception('POST /billing/auto-recharge/setup ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<Map<String, dynamic>> patchAutoRecharge({
    int? mode,
    int? blockCredits,
    int? monthlyCapMicroUsd,
  }) async {
    final body = <String, dynamic>{};
    if (mode != null) body['mode'] = mode;
    if (blockCredits != null) body['block_credits'] = blockCredits;
    if (monthlyCapMicroUsd != null) body['monthly_cap_micro_usd'] = monthlyCapMicroUsd;
    final resp = await _http.patch(
      baseUrl.resolve('/billing/auto-recharge'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200) {
      throw Exception('PATCH /billing/auto-recharge ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<List<Map<String, dynamic>>> listNotifications({int limit = 50, int? sinceId}) async {
    final qs = <String, String>{'limit': '$limit'};
    if (sinceId != null) qs['since_id'] = '$sinceId';
    final resp = await _http.get(
      baseUrl.resolve('/notifications').replace(queryParameters: qs),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('GET /notifications ${resp.statusCode}: ${resp.body}');
    }
    final body = Map<String, dynamic>.from(jsonDecode(resp.body));
    return List<Map<String, dynamic>>.from(body['notifications'] as List);
  }

  Future<void> dismissNotification(int notificationId) async {
    final resp = await _http.post(
      baseUrl.resolve('/notifications/$notificationId/dismiss'),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('POST /notifications/$notificationId/dismiss ${resp.statusCode}');
    }
  }

  Future<List<Map<String, dynamic>>> listNotificationRules() async {
    final resp = await _http.get(
      baseUrl.resolve('/notification_rules'),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('GET /notification_rules ${resp.statusCode}: ${resp.body}');
    }
    final body = Map<String, dynamic>.from(jsonDecode(resp.body));
    return List<Map<String, dynamic>>.from(body['rules'] as List);
  }

  Future<Map<String, dynamic>> createNotificationRule({
    required String kind, required int threshold, bool enabled = true,
  }) async {
    final resp = await _http.post(
      baseUrl.resolve('/notification_rules'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode({'kind': kind, 'threshold': threshold, 'enabled': enabled}),
    );
    if (resp.statusCode != 200) {
      throw Exception('POST /notification_rules ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<Map<String, dynamic>> patchNotificationRule(
    int ruleId, {int? threshold, bool? enabled,
  }) async {
    final body = <String, dynamic>{};
    if (threshold != null) body['threshold'] = threshold;
    if (enabled != null) body['enabled'] = enabled;
    final resp = await _http.patch(
      baseUrl.resolve('/notification_rules/$ruleId'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200) {
      throw Exception('PATCH /notification_rules ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<void> deleteNotificationRule(int ruleId) async {
    final resp = await _http.delete(
      baseUrl.resolve('/notification_rules/$ruleId'),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('DELETE /notification_rules/$ruleId ${resp.statusCode}');
    }
  }

  Future<List<Map<String, dynamic>>> listPushDevices() async {
    final resp = await _http.get(
      baseUrl.resolve('/push/devices'),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('GET /push/devices ${resp.statusCode}: ${resp.body}');
    }
    final body = Map<String, dynamic>.from(jsonDecode(resp.body));
    return List<Map<String, dynamic>>.from(body['devices'] as List);
  }

  Future<Map<String, dynamic>> registerPushDevice({
    required String provider,
    String? endpointUrl,
    String? label,
    String? platform,
  }) async {
    final resp = await _http.post(
      baseUrl.resolve('/push/devices'),
      headers: {'content-type': 'application/json', ...(await _authHeaders)},
      body: jsonEncode({
        'provider': provider,
        if (endpointUrl != null) 'endpoint_url': endpointUrl,
        if (label != null) 'label': label,
        if (platform != null) 'platform': platform,
      }),
    );
    if (resp.statusCode != 200) {
      throw Exception('POST /push/devices ${resp.statusCode}: ${resp.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }

  Future<void> deletePushDevice(int deviceId) async {
    final resp = await _http.delete(
      baseUrl.resolve('/push/devices/$deviceId'),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('DELETE /push/devices/$deviceId ${resp.statusCode}');
    }
  }

  Future<Map<String, dynamic>> getTaskCost(String taskId) async {
    final resp = await _http.get(
      baseUrl.resolve('/tasks/$taskId/cost'),
      headers: await _authHeaders,
    );
    if (resp.statusCode != 200) {
      throw Exception('GET /tasks/$taskId/cost ${resp.statusCode}');
    }
    return Map<String, dynamic>.from(jsonDecode(resp.body));
  }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd tally_coding_app && flutter test test/api_credits_test.dart
```

Expected: 2 PASS.

- [ ] **Step 5: Commit**

```bash
git add tally_coding_app/lib/api.dart tally_coding_app/test/api_credits_test.dart
git commit -m "[s46] api.dart: credits, caps, checkout, auto-recharge, notifications, push devices"
```

### Task B3: CreditBalanceWidget

**Files:**
- Create: `tally_coding_app/lib/widgets/credit_balance_widget.dart`

- [ ] **Step 1: Write the widget**

```dart
// tally_coding_app/lib/widgets/credit_balance_widget.dart
import 'package:flutter/material.dart';

/// Sprint 46: shows credit balance + breakdown.
/// Inputs are denormalized; widget is stateless and pure-display.
class CreditBalanceWidget extends StatelessWidget {
  final String planLabel;
  final bool isBeta;
  final int usedCredits;
  final int includedCredits;
  final int prepaidCreditBalance;
  final double periodStart;

  const CreditBalanceWidget({
    super.key,
    required this.planLabel,
    required this.isBeta,
    required this.usedCredits,
    required this.includedCredits,
    required this.prepaidCreditBalance,
    required this.periodStart,
  });

  @override
  Widget build(BuildContext context) {
    final total = includedCredits + prepaidCreditBalance;
    final remainingIncluded = (includedCredits - usedCredits).clamp(0, includedCredits);
    final pct = total == 0 ? 0.0 : (usedCredits / total).clamp(0.0, 1.0);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(planLabel,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (isBeta) ...[
                  const SizedBox(width: 8),
                  const Chip(label: Text('Beta — locked')),
                ],
              ],
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: pct,
              color: pct < 0.5 ? Colors.green : (pct < 0.8 ? Colors.orange : Colors.red),
              backgroundColor: Colors.grey.shade300,
            ),
            const SizedBox(height: 12),
            Text('$usedCredits / $total credits used'),
            const SizedBox(height: 4),
            Text(
              'Subscription pool: $remainingIncluded · Prepaid balance: $prepaidCreditBalance',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Write a widget test**

Create `tally_coding_app/test/credit_balance_widget_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/credit_balance_widget.dart';

void main() {
  testWidgets('renders plan label and credit count', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: CreditBalanceWidget(
      planLabel: 'Pro (Beta)',
      isBeta: true,
      usedCredits: 250,
      includedCredits: 1000,
      prepaidCreditBalance: 0,
      periodStart: 0,
    ))));
    expect(find.text('Pro (Beta)'), findsOneWidget);
    expect(find.text('Beta — locked'), findsOneWidget);
    expect(find.text('250 / 1000 credits used'), findsOneWidget);
  });

  testWidgets('shows prepaid balance line', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: CreditBalanceWidget(
      planLabel: 'Pro (Beta)',
      isBeta: true,
      usedCredits: 100,
      includedCredits: 1000,
      prepaidCreditBalance: 500,
      periodStart: 0,
    ))));
    expect(find.textContaining('Prepaid balance: 500'), findsOneWidget);
  });
}
```

- [ ] **Step 3: Run test**

```bash
cd tally_coding_app && flutter test test/credit_balance_widget_test.dart
```

Expected: 2 PASS.

- [ ] **Step 4: Commit**

```bash
git add tally_coding_app/lib/widgets/credit_balance_widget.dart tally_coding_app/test/credit_balance_widget_test.dart
git commit -m "[s46] CreditBalanceWidget: plan + progress + prepaid breakdown"
```

### Task B4: Billing screen overhaul

**Files:**
- Modify: `tally_coding_app/lib/screens/billing_screen.dart` — full replacement

- [ ] **Step 1: Replace billing_screen.dart with the new layout**

The new screen is ~450 lines. Save the OLD content to `billing_screen_v1.dart.bak` (not committed) for reference, then rewrite. Top-level structure:

```dart
// tally_coding_app/lib/screens/billing_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api.dart';
import '../widgets/credit_balance_widget.dart';

class BillingScreen extends StatefulWidget {
  final TallyApi api;
  const BillingScreen({super.key, required this.api});
  @override
  State<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends State<BillingScreen> {
  Map<String, dynamic>? _balance;
  Map<String, dynamic>? _caps;
  String? _error;
  bool _loading = true;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final results = await Future.wait([
        widget.api.getCreditsBalance(),
        widget.api.getCaps(),
      ]);
      if (!mounted) return;
      setState(() {
        _balance = results[0];
        _caps = results[1];
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _buyCredits() async {
    final picked = await showDialog<int>(
      context: context,
      builder: (_) => const _CreditPickerDialog(),
    );
    if (picked == null) return;
    try {
      final out = await widget.api.postCreditsCheckout(credits: picked);
      final url = Uri.parse(out['url'] as String);
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _setupAutoRecharge() async {
    try {
      final out = await widget.api.postAutoRechargeSetup();
      final url = Uri.parse(out['url'] as String);
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Billing')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('Error: $_error'))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    CreditBalanceWidget(
                      planLabel: _balance!['plan_label'] as String,
                      isBeta: _balance!['is_beta'] as bool,
                      usedCredits: _balance!['used_credits'] as int,
                      includedCredits: _balance!['included_credits'] as int,
                      prepaidCreditBalance: _balance!['prepaid_credit_balance'] as int,
                      periodStart: (_balance!['period_start'] as num).toDouble(),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(child: OutlinedButton.icon(
                          icon: const Icon(Icons.add),
                          label: const Text('Buy credits'),
                          onPressed: _buyCredits,
                        )),
                        const SizedBox(width: 12),
                        Expanded(child: OutlinedButton.icon(
                          icon: const Icon(Icons.autorenew),
                          label: const Text('Auto-recharge'),
                          onPressed: _setupAutoRecharge,
                        )),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _AutoRechargeCard(
                      api: widget.api,
                      balance: _balance!,
                      onChanged: _refresh,
                    ),
                    const SizedBox(height: 16),
                    _CapsCard(
                      api: widget.api,
                      caps: _caps!,
                      onChanged: _refresh,
                    ),
                    const SizedBox(height: 16),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.notifications_outlined),
                        title: const Text('Notifications & alerts'),
                        subtitle: const Text('Configure spend alerts and devices'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).pushNamed('/notifications'),
                      ),
                    ),
                  ],
                ),
    );
  }
}

// Subwidgets: _CreditPickerDialog, _AutoRechargeCard, _CapsCard
// (see steps 2-4 for the bodies)
```

- [ ] **Step 2: Add `_CreditPickerDialog` at the bottom of billing_screen.dart**

```dart
class _CreditPickerDialog extends StatefulWidget {
  const _CreditPickerDialog();
  @override
  State<_CreditPickerDialog> createState() => _CreditPickerDialogState();
}

class _CreditPickerDialogState extends State<_CreditPickerDialog> {
  int _credits = 500;

  @override
  Widget build(BuildContext context) {
    final usd = (_credits * 0.02);
    return AlertDialog(
      title: const Text('Buy credits'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Slider(
            value: _credits.toDouble(),
            min: 250, max: 5000, divisions: 19,
            label: '$_credits credits',
            onChanged: (v) => setState(() => _credits = v.round()),
          ),
          Text('$_credits credits · \$${usd.toStringAsFixed(2)}'),
          const SizedBox(height: 8),
          const Text('Minimum: 250 credits (\$5)', style: TextStyle(fontSize: 12)),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _credits),
          child: const Text('Buy'),
        ),
      ],
    );
  }
}
```

- [ ] **Step 3: Add `_AutoRechargeCard`**

```dart
class _AutoRechargeCard extends StatefulWidget {
  final TallyApi api;
  final Map<String, dynamic> balance;
  final VoidCallback onChanged;
  const _AutoRechargeCard({required this.api, required this.balance, required this.onChanged});
  @override
  State<_AutoRechargeCard> createState() => _AutoRechargeCardState();
}

class _AutoRechargeCardState extends State<_AutoRechargeCard> {
  late int _mode;
  late int _blockCredits;
  late int? _monthlyCapMicroUsd;

  @override
  void initState() {
    super.initState();
    _mode = widget.balance['auto_recharge_mode'] as int;
    _blockCredits = widget.balance['auto_recharge_block_credits'] as int;
    _monthlyCapMicroUsd = widget.balance['auto_recharge_monthly_cap_micro_usd'] as int?;
  }

  Future<void> _save() async {
    try {
      await widget.api.patchAutoRecharge(
        mode: _mode,
        blockCredits: _blockCredits,
        monthlyCapMicroUsd: _monthlyCapMicroUsd,
      );
      widget.onChanged();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  static const _modes = [
    (0, 'Subscription only', 'Hard stop when credits run out'),
    (1, 'Pre-paid manual', 'Buy credit blocks; no auto-charge'),
    (2, 'Auto-recharge with cap', 'Auto-buy blocks up to monthly limit'),
    (3, 'Full auto (no cap)', 'Never run out; bills as usage grows'),
  ];

  @override
  Widget build(BuildContext context) {
    final hasCard = widget.balance['stripe_payment_method_id'] != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Auto-recharge', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final (id, label, desc) in _modes)
              RadioListTile<int>(
                value: id, groupValue: _mode,
                onChanged: (v) => setState(() => _mode = v!),
                title: Text(label),
                subtitle: Text(desc),
                dense: true,
              ),
            if (_mode >= 2) ...[
              const Divider(),
              Text('Block size: $_blockCredits credits · \$${(_blockCredits * 0.02).toStringAsFixed(2)}'),
              Slider(
                value: _blockCredits.toDouble(),
                min: 250, max: 2500, divisions: 9,
                onChanged: (v) => setState(() => _blockCredits = v.round()),
              ),
              if (_mode == 2) ...[
                const SizedBox(height: 8),
                Text('Monthly cap: \$${((_monthlyCapMicroUsd ?? 0) / 1000000).toStringAsFixed(2)}'),
                Slider(
                  value: ((_monthlyCapMicroUsd ?? 20000000) / 1000000).clamp(5, 500),
                  min: 5, max: 500, divisions: 99,
                  onChanged: (v) => setState(() {
                    _monthlyCapMicroUsd = (v * 1000000).round();
                  }),
                ),
              ],
              if (!hasCard) ...[
                const SizedBox(height: 12),
                const Text('No saved card. Use "Auto-recharge" button above to add one.',
                  style: TextStyle(color: Colors.orange)),
              ],
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(onPressed: _save, child: const Text('Save')),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Add `_CapsCard`**

```dart
class _CapsCard extends StatefulWidget {
  final TallyApi api;
  final Map<String, dynamic> caps;
  final VoidCallback onChanged;
  const _CapsCard({required this.api, required this.caps, required this.onChanged});
  @override
  State<_CapsCard> createState() => _CapsCardState();
}

class _CapsCardState extends State<_CapsCard> {
  late TextEditingController _perTask;
  late TextEditingController _daily;
  late TextEditingController _weekly;

  @override
  void initState() {
    super.initState();
    _perTask = TextEditingController(text: '${widget.caps['per_task_cap_credits'] ?? ''}');
    _daily = TextEditingController(text: '${widget.caps['daily_spend_cap_credits'] ?? ''}');
    _weekly = TextEditingController(text: '${widget.caps['weekly_spend_cap_credits'] ?? ''}');
  }

  @override
  void dispose() {
    _perTask.dispose();
    _daily.dispose();
    _weekly.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    int? parse(String s) => s.trim().isEmpty ? null : int.tryParse(s.trim());
    try {
      await widget.api.patchCaps(
        perTaskCapCredits: parse(_perTask.text),
        dailySpendCapCredits: parse(_daily.text),
        weeklySpendCapCredits: parse(_weekly.text),
      );
      widget.onChanged();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Spend caps', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(controller: _perTask, decoration: const InputDecoration(
              labelText: 'Per-task cap (credits)', hintText: 'e.g. 100',
            ), keyboardType: TextInputType.number),
            const SizedBox(height: 8),
            TextField(controller: _daily, decoration: const InputDecoration(
              labelText: 'Daily cap (credits)', hintText: 'optional',
            ), keyboardType: TextInputType.number),
            const SizedBox(height: 8),
            TextField(controller: _weekly, decoration: const InputDecoration(
              labelText: 'Weekly cap (credits)', hintText: 'optional',
            ), keyboardType: TextInputType.number),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(onPressed: _save, child: const Text('Save')),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 5: Run flutter analyze**

```bash
cd tally_coding_app && flutter analyze lib/screens/billing_screen.dart
```

Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add tally_coding_app/lib/screens/billing_screen.dart
git commit -m "[s46] billing_screen: credit balance + buy / auto-recharge / caps"
```

### Task B5: Composer cost estimate banner

**Files:**
- Create: `tally_coding_app/lib/widgets/cost_estimate_banner.dart`
- Modify: `tally_coding_app/lib/screens/general_channel.dart` — wire banner above the text input

- [ ] **Step 1: Write the widget**

```dart
// tally_coding_app/lib/widgets/cost_estimate_banner.dart
import 'package:flutter/material.dart';

class CostEstimateBanner extends StatelessWidget {
  final int estimatedCredits;
  final int availableCredits;
  final int perTaskCapCredits;
  const CostEstimateBanner({
    super.key,
    required this.estimatedCredits,
    required this.availableCredits,
    required this.perTaskCapCredits,
  });

  Color _color() {
    if (estimatedCredits > availableCredits) return Colors.red;
    if (estimatedCredits > perTaskCapCredits) return Colors.orange;
    if (estimatedCredits > availableCredits ~/ 2) return Colors.amber;
    return Colors.green;
  }

  @override
  Widget build(BuildContext context) {
    final usd = (estimatedCredits * 0.02);
    final color = _color();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: color.withOpacity(0.12),
      child: Row(
        children: [
          Icon(Icons.bolt, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Estimated cost: $estimatedCredits credits (\$${usd.toStringAsFixed(2)}) · '
              '$availableCredits remaining this period',
              style: TextStyle(fontSize: 12, color: color),
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 2: Add a tiny cost estimator helper**

In `tally_coding_app/lib/widgets/cost_estimate_banner.dart` at the bottom, export:

```dart
/// Sprint 46: client-side cost estimate.  Heuristic only — server
/// authoritatively rejects at the credit gate.
int estimateCreditsClientSide(String description) {
  if (description.isEmpty) return 0;
  // Simple: 4 chars ≈ 1 prompt token, llama-3.3 70b at $0.59/M prompt
  // + $0.79/M completion. Assume completion ≈ 0.2× prompt.
  final tokens = (description.length / 4).round();
  final usdProm = tokens * 0.59 / 1_000_000;
  final usdComp = tokens * 0.2 * 0.79 / 1_000_000;
  final usdTotal = usdProm + usdComp;
  return (usdTotal * 100).ceil();  // credits (1 credit = $0.01)
}
```

- [ ] **Step 3: Wire banner into general_channel.dart**

Open `tally_coding_app/lib/screens/general_channel.dart`. Find the text composer (a `TextField` with the task description, somewhere below the agent palette). Above it (in the `Column` of children), add:

```dart
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _descController,
                builder: (context, value, _) {
                  final est = estimateCreditsClientSide(value.text);
                  return CostEstimateBanner(
                    estimatedCredits: est,
                    availableCredits: _availableCredits,
                    perTaskCapCredits: _perTaskCap,
                  );
                },
              ),
```

Where `_descController` is the existing text controller and `_availableCredits` / `_perTaskCap` are state fields populated in `initState` by calling `widget.api.getCreditsBalance()` + `widget.api.getCaps()`. Add those fields:

```dart
  int _availableCredits = 0;
  int _perTaskCap = 100;
  // … in initState, alongside the existing initial fetches:
  unawaited(_refreshCreditState());

  Future<void> _refreshCreditState() async {
    try {
      final results = await Future.wait([
        widget.api.getCreditsBalance(),
        widget.api.getCaps(),
      ]);
      if (!mounted) return;
      setState(() {
        _availableCredits = results[0]['available_credits'] as int;
        _perTaskCap = results[1]['per_task_cap_credits'] as int;
      });
    } catch (_) {
      // banner stays at defaults; no UX impact
    }
  }
```

Add the import `import '../widgets/cost_estimate_banner.dart';` and `import 'dart:async';` for `unawaited`.

- [ ] **Step 4: Widget test**

Create `tally_coding_app/test/cost_estimate_banner_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/cost_estimate_banner.dart';

void main() {
  testWidgets('shows estimate text', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: CostEstimateBanner(
      estimatedCredits: 25,
      availableCredits: 1000,
      perTaskCapCredits: 100,
    ))));
    expect(find.textContaining('Estimated cost: 25 credits'), findsOneWidget);
  });

  test('estimateCreditsClientSide for short string', () {
    final out = estimateCreditsClientSide('write hello world');
    expect(out, greaterThanOrEqualTo(0));
    expect(out, lessThan(10));  // tiny task
  });

  test('estimateCreditsClientSide scales with length', () {
    final small = estimateCreditsClientSide('x' * 100);
    final big = estimateCreditsClientSide('x' * 10000);
    expect(big, greaterThan(small));
  });
}
```

- [ ] **Step 5: Run tests**

```bash
cd tally_coding_app && flutter test test/cost_estimate_banner_test.dart && flutter analyze lib/screens/general_channel.dart
```

Expected: 3 PASS + analyze clean.

- [ ] **Step 6: Commit**

```bash
git add tally_coding_app/lib/widgets/cost_estimate_banner.dart tally_coding_app/lib/screens/general_channel.dart tally_coding_app/test/cost_estimate_banner_test.dart
git commit -m "[s46] CostEstimateBanner: composer cost estimate + client-side helper"
```

### Task B6: Task channel live cost ticker + cap-abort dialog

**Files:**
- Create: `tally_coding_app/lib/widgets/task_cost_ticker.dart`
- Create: `tally_coding_app/lib/widgets/cap_abort_dialog.dart`
- Modify: `tally_coding_app/lib/screens/task_channel.dart` — add chip in header + dialog on status `aborted_cost_cap`

- [ ] **Step 1: Write `TaskCostTicker`**

```dart
// tally_coding_app/lib/widgets/task_cost_ticker.dart
import 'dart:async';
import 'package:flutter/material.dart';
import '../api.dart';

class TaskCostTicker extends StatefulWidget {
  final TallyApi api;
  final String taskId;
  final int perTaskCapCredits;
  final String taskStatus;
  const TaskCostTicker({
    super.key,
    required this.api,
    required this.taskId,
    required this.perTaskCapCredits,
    required this.taskStatus,
  });
  @override
  State<TaskCostTicker> createState() => _TaskCostTickerState();
}

class _TaskCostTickerState extends State<TaskCostTicker> {
  int _credits = 0;
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _poll();
    if (widget.taskStatus == 'running' || widget.taskStatus == 'pending') {
      _t = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
    }
  }

  @override
  void didUpdateWidget(covariant TaskCostTicker old) {
    super.didUpdateWidget(old);
    final shouldRun = widget.taskStatus == 'running' || widget.taskStatus == 'pending';
    if (shouldRun && _t == null) {
      _t = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
    } else if (!shouldRun && _t != null) {
      _t!.cancel();
      _t = null;
    }
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    try {
      final out = await widget.api.getTaskCost(widget.taskId);
      final micro = (out['total_micro_usd'] as num).toInt();
      final credits = (micro + 9_999) ~/ 10_000;  // round-up like server
      if (!mounted) return;
      setState(() => _credits = credits);
    } catch (_) {
      // silent — don't crash UI on transient network errors
    }
  }

  Color _color() {
    if (_credits > widget.perTaskCapCredits) return Colors.red;
    if (_credits > widget.perTaskCapCredits * 0.8) return Colors.orange;
    return Colors.green;
  }

  @override
  Widget build(BuildContext context) {
    final usd = _credits * 0.02;
    return Chip(
      avatar: Icon(Icons.attach_money, size: 16, color: _color()),
      label: Text('$_credits credits  \$${usd.toStringAsFixed(2)}'),
      backgroundColor: _color().withOpacity(0.12),
    );
  }
}
```

- [ ] **Step 2: Write `CapAbortDialog`**

```dart
// tally_coding_app/lib/widgets/cap_abort_dialog.dart
import 'package:flutter/material.dart';

class CapAbortDialog extends StatelessWidget {
  final int costCredits;
  final int capCredits;
  final VoidCallback onRaiseCapAndRetry;
  final VoidCallback onViewPartial;
  const CapAbortDialog({
    super.key,
    required this.costCredits,
    required this.capCredits,
    required this.onRaiseCapAndRetry,
    required this.onViewPartial,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.block, color: Colors.red),
      title: const Text('Cost cap reached'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This task spent $costCredits credits, exceeding your '
            '$capCredits-credit per-task cap. Remaining agents were '
            'skipped to protect your balance.',
          ),
          const SizedBox(height: 12),
          const Text(
            'Partial artifacts are preserved. You can review what '
            'completed or raise your cap and retry.',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: onViewPartial, child: const Text('View partial')),
        FilledButton(onPressed: onRaiseCapAndRetry, child: const Text('Raise cap & retry')),
      ],
    );
  }
}
```

- [ ] **Step 3: Wire into task_channel.dart**

Open `tally_coding_app/lib/screens/task_channel.dart`. Find the channel header (existing `channel_header.dart` widget or inline `AppBar`). Add the ticker:

```dart
              actions: [
                if (taskStatus == 'running' || taskStatus == 'pending' ||
                    taskStatus == 'completed')
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: TaskCostTicker(
                      api: widget.api,
                      taskId: widget.taskId,
                      perTaskCapCredits: _perTaskCap,
                      taskStatus: taskStatus,
                    ),
                  ),
              ],
```

In the SSE event handler (where status updates land), when an event is received with status `aborted_cost_cap`, show the dialog:

```dart
              if (event['status'] == 'aborted_cost_cap') {
                final detail = event['extra'] as Map<String, dynamic>? ?? {};
                showDialog(
                  context: context,
                  builder: (_) => CapAbortDialog(
                    costCredits: detail['cost_credits'] as int? ?? 0,
                    capCredits: detail['cap_credits'] as int? ?? 0,
                    onViewPartial: () {
                      Navigator.pop(context);
                      // Existing "view artifacts" flow
                    },
                    onRaiseCapAndRetry: () {
                      Navigator.pop(context);
                      Navigator.of(context).pushNamed('/billing');
                    },
                  ),
                );
              }
```

Add imports at top:
```dart
import '../widgets/task_cost_ticker.dart';
import '../widgets/cap_abort_dialog.dart';
```

- [ ] **Step 4: Widget test for CapAbortDialog**

Create `tally_coding_app/test/cap_abort_dialog_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally_coding_app/widgets/cap_abort_dialog.dart';

void main() {
  testWidgets('renders cap + cost numbers', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (ctx) {
      return ElevatedButton(onPressed: () => showDialog(
        context: ctx,
        builder: (_) => CapAbortDialog(
          costCredits: 105,
          capCredits: 100,
          onRaiseCapAndRetry: () {},
          onViewPartial: () {},
        ),
      ), child: const Text('open'));
    }))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('105 credits'), findsOneWidget);
    expect(find.textContaining('100-credit'), findsOneWidget);
    expect(find.text('Raise cap & retry'), findsOneWidget);
  });
}
```

- [ ] **Step 5: Run tests + analyze**

```bash
cd tally_coding_app && flutter test test/cap_abort_dialog_test.dart && flutter analyze lib/screens/task_channel.dart
```

Expected: 1 PASS, analyze clean.

- [ ] **Step 6: Commit**

```bash
git add tally_coding_app/lib/widgets/task_cost_ticker.dart tally_coding_app/lib/widgets/cap_abort_dialog.dart tally_coding_app/lib/screens/task_channel.dart tally_coding_app/test/cap_abort_dialog_test.dart
git commit -m "[s46] task channel: cost ticker chip + cap-abort dialog"
```


### Task B7: NotificationsScreen — inbox + dismiss

**Files:**
- Create: `tally_coding_app/lib/screens/notifications_screen.dart`
- Modify: `tally_coding_app/lib/main.dart` — register `/notifications` route

- [ ] **Step 1: Write `NotificationsScreen` with three tabs**

```dart
// tally_coding_app/lib/screens/notifications_screen.dart
import 'package:flutter/material.dart';
import '../api.dart';
import '../services/unified_push.dart';
import '../services/desktop_notifier.dart';

class NotificationsScreen extends StatelessWidget {
  final TallyApi api;
  const NotificationsScreen({super.key, required this.api});
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Notifications'),
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.inbox), text: 'Inbox'),
            Tab(icon: Icon(Icons.rule), text: 'Alert rules'),
            Tab(icon: Icon(Icons.devices), text: 'Devices'),
          ]),
        ),
        body: TabBarView(children: [
          _InboxTab(api: api),
          _RulesTab(api: api),
          _DevicesTab(api: api),
        ]),
      ),
    );
  }
}

class _InboxTab extends StatefulWidget {
  final TallyApi api;
  const _InboxTab({required this.api});
  @override
  State<_InboxTab> createState() => _InboxTabState();
}

class _InboxTabState extends State<_InboxTab> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final items = await widget.api.listNotifications();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _dismiss(int id) async {
    try {
      await widget.api.dismissNotification(id);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_items.isEmpty) {
      return const Center(child: Text('No notifications yet.'));
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        itemCount: _items.length,
        itemBuilder: (ctx, i) {
          final n = _items[i];
          final sev = n['severity'] as String? ?? 'info';
          final icon = sev == 'error' ? Icons.error_outline
              : sev == 'warning' ? Icons.warning_amber
              : Icons.info_outline;
          final color = sev == 'error' ? Colors.red
              : sev == 'warning' ? Colors.orange
              : Colors.blue;
          return Dismissible(
            key: ValueKey(n['id']),
            background: Container(color: Colors.green, alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 16),
              child: const Icon(Icons.check, color: Colors.white)),
            onDismissed: (_) => _dismiss(n['id'] as int),
            child: ListTile(
              leading: Icon(icon, color: color),
              title: Text(n['kind'] as String),
              subtitle: Text(n['payload_json'] as String),
            ),
          );
        },
      ),
    );
  }
}

class _RulesTab extends StatefulWidget {
  final TallyApi api;
  const _RulesTab({required this.api});
  @override
  State<_RulesTab> createState() => _RulesTabState();
}

class _RulesTabState extends State<_RulesTab> {
  List<Map<String, dynamic>> _rules = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final out = await widget.api.listNotificationRules();
      if (!mounted) return;
      setState(() { _rules = out; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _add() async {
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const _RuleEditorDialog(),
    );
    if (picked == null) return;
    try {
      await widget.api.createNotificationRule(
        kind: picked['kind'] as String,
        threshold: picked['threshold'] as int,
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _toggle(Map<String, dynamic> rule) async {
    try {
      await widget.api.patchNotificationRule(rule['id'] as int,
        enabled: !(rule['enabled'] as bool));
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _delete(int id) async {
    try {
      await widget.api.deleteNotificationRule(id);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      if (_loading) const Center(child: CircularProgressIndicator())
      else if (_rules.isEmpty) const Center(child: Text('No alert rules. Tap + to add one.'))
      else ListView.builder(
        itemCount: _rules.length,
        itemBuilder: (ctx, i) {
          final r = _rules[i];
          return ListTile(
            leading: Switch(value: r['enabled'] as bool, onChanged: (_) => _toggle(r)),
            title: Text('${r['kind']} ≥ ${r['threshold']}'),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _delete(r['id'] as int),
            ),
          );
        },
      ),
      Positioned(
        bottom: 16, right: 16,
        child: FloatingActionButton(onPressed: _add, child: const Icon(Icons.add)),
      ),
    ]);
  }
}

class _RuleEditorDialog extends StatefulWidget {
  const _RuleEditorDialog();
  @override
  State<_RuleEditorDialog> createState() => _RuleEditorDialogState();
}

class _RuleEditorDialogState extends State<_RuleEditorDialog> {
  String _kind = 'period_pct';
  final _threshold = TextEditingController(text: '80');

  static const _kinds = [
    ('period_pct', 'Period % used'),
    ('daily_amount', 'Daily credit total'),
    ('weekly_amount', 'Weekly credit total'),
    ('per_task_amount', 'Single task credits'),
    ('auto_recharge_monthly_pct', 'Auto-recharge monthly % used'),
  ];

  @override
  void dispose() {
    _threshold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New alert rule'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButton<String>(
            value: _kind,
            onChanged: (v) => setState(() => _kind = v!),
            items: [for (final (id, label) in _kinds)
              DropdownMenuItem(value: id, child: Text(label))],
          ),
          TextField(
            controller: _threshold,
            decoration: const InputDecoration(labelText: 'Threshold'),
            keyboardType: TextInputType.number,
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final t = int.tryParse(_threshold.text);
            if (t == null || t <= 0) return;
            Navigator.pop(context, {'kind': _kind, 'threshold': t});
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}

class _DevicesTab extends StatefulWidget {
  final TallyApi api;
  const _DevicesTab({required this.api});
  @override
  State<_DevicesTab> createState() => _DevicesTabState();
}

class _DevicesTabState extends State<_DevicesTab> {
  List<Map<String, dynamic>> _devices = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final out = await widget.api.listPushDevices();
      if (!mounted) return;
      setState(() { _devices = out; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _addAndroid() async {
    try {
      final endpoint = await UnifiedPushManager.instance.registerAndPickEndpoint(context);
      if (endpoint == null) return;
      await widget.api.registerPushDevice(
        provider: 'unifiedpush',
        endpointUrl: endpoint,
        label: 'Android (UnifiedPush)',
        platform: 'android',
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _addDesktop() async {
    try {
      final ok = await DesktopNotifier.instance.requestPermission();
      if (!ok) return;
      await widget.api.registerPushDevice(
        provider: 'desktop_local',
        label: 'Linux desktop',
        platform: 'linux',
      );
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _delete(int id) async {
    try {
      await widget.api.deletePushDevice(id);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      if (_loading) const Center(child: CircularProgressIndicator())
      else ListView(children: [
        ..._devices.map((d) => ListTile(
          leading: Icon(d['provider'] == 'unifiedpush' ? Icons.android : Icons.desktop_windows),
          title: Text(d['label'] as String? ?? d['provider'] as String),
          subtitle: Text('${d['provider']} · ${d['platform'] ?? 'unknown'}'),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(d['id'] as int),
          ),
        )),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.add_to_home_screen),
          title: const Text('Add Android device (UnifiedPush)'),
          subtitle: const Text('Privacy-respecting push via your distributor'),
          onTap: _addAndroid,
        ),
        ListTile(
          leading: const Icon(Icons.desktop_windows),
          title: const Text('Add desktop notifications'),
          subtitle: const Text('Native libnotify on Linux'),
          onTap: _addDesktop,
        ),
      ]),
    ]);
  }
}
```

- [ ] **Step 2: Wire route in main.dart**

In `tally_coding_app/lib/main.dart`, find the route table (`routes:` or `onGenerateRoute:`). Add:

```dart
        routes: {
          // ... existing routes ...
          '/notifications': (_) => NotificationsScreen(api: api),
        },
```

Add import: `import 'screens/notifications_screen.dart';`.

- [ ] **Step 3: Add notification icon to discord_shell rail**

In `tally_coding_app/lib/screens/discord_shell.dart` find the rail / sidebar where existing icons (billing, projects, templates) live. Add:

```dart
              IconButton(
                icon: const Icon(Icons.notifications_outlined),
                tooltip: 'Notifications',
                onPressed: () => Navigator.of(context).pushNamed('/notifications'),
              ),
```

- [ ] **Step 4: Analyze**

```bash
cd tally_coding_app && flutter analyze lib/screens/notifications_screen.dart
```

Expected: errors only about `UnifiedPushManager` and `DesktopNotifier` (we add those in B8/B9).

- [ ] **Step 5: Commit (deferred — depends on B8/B9 services)**

Hold the commit until B8 + B9 land, since the screen imports services that don't exist yet. Move to B8 next.

### Task B8: UnifiedPush integration (Android only)

**Files:**
- Create: `tally_coding_app/lib/services/unified_push.dart`
- Modify: `tally_coding_app/android/app/src/main/AndroidManifest.xml`

- [ ] **Step 1: Write the wrapper**

```dart
// tally_coding_app/lib/services/unified_push.dart
import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:unifiedpush/unifiedpush.dart';

class UnifiedPushManager {
  UnifiedPushManager._();
  static final UnifiedPushManager instance = UnifiedPushManager._();

  /// On Android, opens the UnifiedPush distributor picker, registers
  /// our app for messages, and waits for the distributor to hand back
  /// an endpoint URL we can give the orchestrator.
  ///
  /// Returns null if the user cancels or no distributor is installed.
  /// On non-Android platforms, returns null silently.
  Future<String?> registerAndPickEndpoint(BuildContext context) async {
    if (!Platform.isAndroid) return null;
    final completer = Completer<String?>();

    // Listen for endpoint registration.  UnifiedPush delivers it
    // through the plugin's stream once the distributor accepts.
    final sub = UnifiedPush.onNewEndpointStream().listen((event) {
      if (!completer.isCompleted) completer.complete(event.endpoint);
    });
    UnifiedPush.onRegistrationFailedStream().listen((_) {
      if (!completer.isCompleted) completer.complete(null);
    });
    UnifiedPush.onUnregisteredStream().listen((_) {
      if (!completer.isCompleted) completer.complete(null);
    });

    // Pop the distributor picker.  If none installed, the plugin
    // throws; we catch and ask the user to install ntfy from F-Droid.
    try {
      await UnifiedPush.registerAppWithDialog(context, 'tally-default');
    } catch (e) {
      sub.cancel();
      if (!context.mounted) return null;
      await showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('No UnifiedPush distributor installed'),
          content: const Text(
            'Install one from F-Droid (ntfy recommended) to receive '
            'push notifications. Tally never sends your notification '
            'content to Google.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(_), child: const Text('OK')),
          ],
        ),
      );
      return null;
    }

    // 15 second timeout in case distributor hangs.
    final endpoint = await completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => null,
    );
    sub.cancel();
    return endpoint;
  }
}
```

- [ ] **Step 2: Add UnifiedPush receiver to AndroidManifest.xml**

In `tally_coding_app/android/app/src/main/AndroidManifest.xml`, inside `<application>`, add:

```xml
        <receiver
            android:exported="true"
            android:name="org.unifiedpush.flutter.connector.UnifiedPushReceiver">
            <intent-filter>
                <action android:name="org.unifiedpush.android.connector.MESSAGE" />
                <action android:name="org.unifiedpush.android.connector.UNREGISTERED" />
                <action android:name="org.unifiedpush.android.connector.NEW_ENDPOINT" />
                <action android:name="org.unifiedpush.android.connector.REGISTRATION_FAILED" />
            </intent-filter>
        </receiver>
```

- [ ] **Step 3: Smoke check that wrapper imports**

```bash
cd tally_coding_app && flutter analyze lib/services/unified_push.dart
```

Expected: clean (the actual end-to-end test happens during Phase C smoke against a real device).

- [ ] **Step 4: Commit**

```bash
git add tally_coding_app/lib/services/unified_push.dart tally_coding_app/android/app/src/main/AndroidManifest.xml
git commit -m "[s46] UnifiedPushManager: distributor picker + endpoint registration"
```

### Task B9: Desktop notifier (Linux libnotify)

**Files:**
- Create: `tally_coding_app/lib/services/desktop_notifier.dart`

- [ ] **Step 1: Write the wrapper**

```dart
// tally_coding_app/lib/services/desktop_notifier.dart
import 'dart:io' show Platform;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class DesktopNotifier {
  DesktopNotifier._();
  static final DesktopNotifier instance = DesktopNotifier._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _inited = false;

  Future<bool> requestPermission() async {
    if (!Platform.isLinux) return false;
    if (!_inited) {
      const init = InitializationSettings(
        linux: LinuxInitializationSettings(defaultActionName: 'Open'),
      );
      await _plugin.initialize(init);
      _inited = true;
    }
    // libnotify doesn't require explicit permission; treat as granted.
    return true;
  }

  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!Platform.isLinux) return;
    if (!_inited) await requestPermission();
    await _plugin.show(
      id, title, body,
      const NotificationDetails(
        linux: LinuxNotificationDetails(),
      ),
    );
  }
}
```

- [ ] **Step 2: Smoke import**

```bash
cd tally_coding_app && flutter analyze lib/services/desktop_notifier.dart
```

Expected: clean.

- [ ] **Step 3: Commit (with B7 + B8 now)**

```bash
git add tally_coding_app/lib/services/desktop_notifier.dart tally_coding_app/lib/screens/notifications_screen.dart tally_coding_app/lib/main.dart tally_coding_app/lib/screens/discord_shell.dart
git commit -m "[s46] DesktopNotifier + NotificationsScreen + rail icon"
```

### Task B10: WebSocket client + foreground notification handler

**Files:**
- Create: `tally_coding_app/lib/services/notifications_ws.dart`
- Modify: `tally_coding_app/lib/main.dart` — start WebSocket on auth and pipe to local notifier

- [ ] **Step 1: Write the client**

```dart
// tally_coding_app/lib/services/notifications_ws.dart
import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../api.dart';
import 'desktop_notifier.dart';

class NotificationsWsClient {
  final TallyApi api;
  final Uri wsUrl;
  final String Function() bearerProvider;
  WebSocketChannel? _channel;
  Timer? _reconnect;
  StreamSubscription? _sub;
  int _backoffSeconds = 1;
  void Function(Map<String, dynamic>)? onNotification;

  NotificationsWsClient({required this.api, required this.wsUrl, required this.bearerProvider});

  Future<void> connect() async {
    final token = bearerProvider();
    final uri = wsUrl.replace(queryParameters: {'token': token});
    try {
      _channel = WebSocketChannel.connect(uri);
      _sub = _channel!.stream.listen(
        _handleMessage,
        onError: (e) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
      );
      _backoffSeconds = 1;  // reset on successful connect
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _sub?.cancel();
    _channel?.sink.close();
    _reconnect?.cancel();
    _reconnect = Timer(Duration(seconds: _backoffSeconds), () {
      _backoffSeconds = (_backoffSeconds * 2).clamp(1, 60);
      connect();
    });
  }

  Future<void> _handleMessage(dynamic raw) async {
    final msg = jsonDecode(raw as String) as Map<String, dynamic>;
    if (msg['type'] == 'hello') return;
    if (msg['type'] == 'pong') return;
    if (msg['type'] == 'new_notification') {
      final id = msg['id'] as int;
      try {
        // Fetch the notification body over TLS (doorbell pattern: ws
        // wakes us; REST gets content).
        final all = await api.listNotifications(limit: 1, sinceId: id - 1);
        for (final n in all) {
          if (n['id'] == id) {
            onNotification?.call(n);
            // Show OS-native notification on Linux desktop
            await DesktopNotifier.instance.showNotification(
              id: id,
              title: n['kind'] as String,
              body: n['payload_json'] as String? ?? '',
            );
            break;
          }
        }
      } catch (_) {
        // network blip; the inbox tab will catch up on next refresh
      }
    }
  }

  void dispose() {
    _reconnect?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
  }
}
```

- [ ] **Step 2: Start WS in main.dart**

In `tally_coding_app/lib/main.dart`, after the user authenticates (where the existing `TallyApi` is constructed and signed-in state is established), construct and connect the WS:

```dart
              final ws = NotificationsWsClient(
                api: api,
                wsUrl: Uri.parse(baseUrl).replace(
                  scheme: baseUrl.startsWith('https') ? 'wss' : 'ws',
                  path: '/ws/notifications',
                ),
                bearerProvider: () async {
                  return (await bearerProvider()) ?? '';
                } as String Function(),
              );
              unawaited(ws.connect());
```

The exact placement depends on the existing auth scaffold; the goal is: WS lifetime tied to auth state, disconnect on sign-out. If main.dart already has a signed-in widget tree, put ws creation in its `initState`.

- [ ] **Step 3: Analyze**

```bash
cd tally_coding_app && flutter analyze lib/services/notifications_ws.dart
```

Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add tally_coding_app/lib/services/notifications_ws.dart tally_coding_app/lib/main.dart
git commit -m "[s46] NotificationsWsClient: live WS + reconnect + doorbell-then-fetch"
```

### Task B11: Phase B smoke — manual UI walkthrough

**Files:**
- None.

- [ ] **Step 1: Build the Flutter app for Linux**

```bash
cd tally_coding_app && flutter build linux --debug
```

Expected: build succeeds.

- [ ] **Step 2: Run with the orchestrator from Task A19 still alive**

```bash
cd tally_coding_app && TALLY_API_URL=http://localhost:8118 flutter run -d linux
```

- [ ] **Step 3: Manual checklist**

- [ ] Billing screen loads, shows plan + credit balance widget
- [ ] "Buy credits" opens the credit picker dialog
- [ ] "Auto-recharge" radio buttons render four modes
- [ ] "Save" persists caps; reloading the screen shows new values
- [ ] Composer cost estimate banner shows credits + colour-codes
- [ ] Notifications screen opens via rail icon, shows three tabs
- [ ] Add a desktop_local push device → succeeds
- [ ] Create a notification rule → appears in list
- [ ] Toggle / delete the rule → persists across reload

- [ ] **Step 4: Run full flutter test**

```bash
cd tally_coding_app && flutter test
```

Expected: all PASS (including all Phase B widget tests).

- [ ] **Step 5: Tag Phase B done**

```bash
git tag s46-phase-b-done
```


---

## Phase C — docs-site, calibration, deploy

6 tasks (~6h). Builds on a clean `s46-phase-b-done` tag. Phase C produces the public pricing page, calibrates cost estimates against real samples, then ships `tally-orch:v26` to production.

### Task C1: Scaffold tally-coding docs-site (Astro + Starlight)

**Files:**
- Create: `docs-site/` at repo root — Astro + Starlight scaffold, mirroring skytale's structure

- [ ] **Step 1: Scaffold via npm**

```bash
cd ~/Projects/pronoic/tally-coding && npm create astro@latest docs-site -- \
  --template starlight --no-install --no-git --typescript strict --yes
```

Expected: `docs-site/` populated with Starlight defaults.

- [ ] **Step 2: Customise astro.config.mjs**

Replace `docs-site/astro.config.mjs` with:

```javascript
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://tally.codes',
  integrations: [
    starlight({
      title: 'Tally Coding',
      description: 'Privacy-first multi-agent coding workspace.',
      social: [
        { icon: 'github', label: 'GitHub',
          href: 'https://github.com/nicholasraimbault/tally-coding' },
      ],
      sidebar: [
        { label: 'Pricing', link: '/pricing/' },
        { label: 'Docs', items: [
          { label: 'Quick start', link: '/docs/quickstart/' },
        ]},
      ],
    }),
  ],
});
```

- [ ] **Step 3: Add LICENSE notice + package.json license field**

In `docs-site/package.json`, set:

```json
"license": "BUSL-1.1",
```

- [ ] **Step 4: Install deps**

```bash
cd docs-site && npm install
```

Expected: dependencies installed, no errors.

- [ ] **Step 5: Boot dev server, hit /**

```bash
cd docs-site && npm run dev &
sleep 3 && curl -sf http://localhost:4321/ | head -20
kill %1
```

Expected: HTML page with `Tally Coding` in the title.

- [ ] **Step 6: Commit**

```bash
git add docs-site/
git commit -m "[s46] docs-site: Astro + Starlight scaffold (BUSL-1.1)"
```

### Task C2: Public beta pricing page

**Files:**
- Create: `docs-site/src/content/docs/pricing.mdx`
- Create: `docs-site/src/content/docs/index.mdx` — hero with link to pricing

- [ ] **Step 1: Write pricing.mdx**

```mdx
---
title: Pricing
description: Privacy-first beta pricing for Tally Coding.
---

import { Card, CardGrid } from '@astrojs/starlight/components';

## Beta pricing — locked for the life of your subscription

Tally Coding is in private beta. Beta subscribers lock these rates
forever — when we ship stable, new customers pay higher prices, but
yours stays the same as long as you don't cancel.

<CardGrid>
  <Card title="Free">
    **$0/mo**

    - 50 credits ($0.50 of compute)
    - 25-credit cap per task
    - llama-3.3-70b only
    - No overage
  </Card>
  <Card title="Pro (Beta)">
    **$15/mo**

    - 1,000 credits ($10 of compute)
    - 100-credit cap per task (adjustable)
    - All models, S42 routing
    - Overage available
  </Card>
  <Card title="Max (Beta)">
    **$75/mo**

    - 5,000 credits ($50 of compute)
    - 500-credit cap per task (adjustable)
    - All models, S42 routing
    - Overage available
  </Card>
  <Card title="Ultra (Beta)">
    **$150/mo**

    - 10,000 credits ($100 of compute)
    - 1,000-credit cap per task (adjustable)
    - All models, S42 routing
    - Overage available
  </Card>
</CardGrid>

## How credits work

1 credit = $0.01 of LLM compute. Every model call (architect, agents)
costs credits based on actual token usage. We surface real-time spend
in the app — you'll never get a surprise bill.

- **Subscription credits** roll over monthly, expire at period end.
- **Overage credits** (one-time purchase or auto-recharge) never expire.
- **Overage rate**: $0.02 per credit across all tiers.

## Hard caps

Every paid tier has a per-task cost cap (default shown above; you can
raise or lower it). When a task hits its cap, remaining agents are
skipped to protect your balance. Partial artifacts are preserved.

You can also set daily and weekly spend caps. Combined, these make it
**mathematically impossible** to spend more than you intend.

## Overage modes

| Mode | What happens at zero balance |
|---|---|
| Subscription only | Hard stop until next period |
| Pre-paid manual | Hard stop; you top up when ready |
| Auto-recharge with cap | Auto-buys up to your monthly limit |
| Full auto (no cap) | Never runs out; bills as usage grows |

## FAQ

**Will my beta price increase?**
Not as long as you don't cancel. When stable launches, new customers
pay the stable rate; you keep the beta rate.

**What if I exceed my cap?**
The task aborts gracefully with partial artifacts preserved. You can
raise the cap and re-run, or work with what completed.

**Do I need to give you my LLM API key?**
No. Beta includes inference. Enterprise (post-beta) supports bring-
your-own keys for Anthropic, OpenAI, and Red Pill.

**How private are notifications?**
Push wakes use the "doorbell pattern": empty signals only. Content
fetches over authenticated TLS directly from us. No notification
content transits Google FCM, Apple APNs, or any third-party service.
```

- [ ] **Step 2: Write index.mdx hero**

```mdx
---
title: Tally Coding
description: Privacy-first multi-agent coding workspace.
template: splash
hero:
  tagline: Run a team of AI agents on your code. Privately. In a TEE.
  actions:
    - text: See pricing
      link: /pricing/
      icon: right-arrow
      variant: primary
    - text: GitHub
      link: https://github.com/nicholasraimbault/tally-coding
      icon: external
---

Tally Coding gives you a Discord-shaped workspace where AI agents
collaborate on your engineering tasks. Tally picks a custom team for
each task, runs them in a Trusted Execution Environment, and feeds
artifacts between agents so your code stays end-to-end encrypted.
```

- [ ] **Step 3: Build static site**

```bash
cd docs-site && npm run build
```

Expected: `dist/` populated; no broken-link warnings.

- [ ] **Step 4: Spot-check pricing page**

```bash
cd docs-site && npm run preview &
sleep 3 && curl -sf http://localhost:4321/pricing/ | grep -E "Pro \(Beta\)|1,000 credits"
kill %1
```

Expected: matches found.

- [ ] **Step 5: Commit**

```bash
git add docs-site/src/content/docs/
git commit -m "[s46] docs-site: hero + beta pricing page"
```

### Task C3: Sample-task calibration of cost estimates

**Files:**
- Modify: `services/orchestrator/tally_orchestrator/cost_estimate.py` — replace placeholder constants with calibrated values
- Create: `docs/SPRINT-46-CALIBRATION-RUN.md` — record what we learned

- [ ] **Step 1: Submit 10 sample tasks against the live orchestrator**

Run these via the Flutter app or curl, against the prod-deployed orchestrator from Task C5. (If Task C5 hasn't run yet, do this against the locally-running orchestrator from A19 with a placeholder Red Pill key.)

Tasks to run (4 simple, 4 medium, 2 hard):

- Simple (llama-only): "write a python function that reverses a string"
- Simple (llama-only): "what is the time complexity of bubble sort?"
- Simple (llama-only): "convert 100 fahrenheit to celsius in python"
- Simple (llama-only): "regex for matching e164 phone numbers"
- Medium (kimi+llama): "implement merge-sort with a unit test"
- Medium (kimi+llama): "write a Flask endpoint that proxies GET requests to JSONPlaceholder"
- Medium (kimi+llama): "refactor a 200-line python function into smaller helpers"
- Medium (kimi+llama): "write a typescript class that wraps Redis pub/sub"
- Hard (full S42): "build a CLI tool that ingests a CSV and inserts into Postgres with idempotency"
- Hard (full S42): "implement a tiny lisp evaluator with let, lambda, and if"

- [ ] **Step 2: Pull cost_events from the live DB**

```bash
# On the orchestrator host (or via SSH per CLAUDE.local.md)
sqlite3 /var/lib/tally/orchestrator.db \
  "SELECT task_id, kind, model, prompt_tokens, completion_tokens, total_tokens, cost_micro_usd \
   FROM cost_events WHERE ts > $(date -d '1 hour ago' +%s) ORDER BY task_id, ts"
```

- [ ] **Step 3: Compute medians per (model, task-class)**

```python
# In a local python repl
import statistics
# Group by model. For each, median (prompt, completion).
# Example results (record actual values):
# llama-3.3-70b: prompt median ≈ 800, completion median ≈ 250
# kimi-k2.6: prompt median ≈ 3500, completion median ≈ 700
```

- [ ] **Step 4: Update `cost_estimate.py` constants**

In `services/orchestrator/tally_orchestrator/cost_estimate.py`, replace:

```python
DEFAULT_PROMPT_TOKENS = 4000
DEFAULT_COMPLETION_TOKENS = 800
PROMPT_TOKENS_PER_CHAR = 4
COMPLETION_TOKENS_PER_CHAR = 1
```

with calibrated values (USE ACTUAL NUMBERS from step 3, the values below are illustrative placeholders):

```python
# Calibrated from 10 sample tasks on 2026-05-21.  See
# docs/SPRINT-46-CALIBRATION-RUN.md.  Re-run when models change or
# every ~3 months.
DEFAULT_PROMPT_TOKENS = 2500
DEFAULT_COMPLETION_TOKENS = 600
PROMPT_TOKENS_PER_CHAR = 3
COMPLETION_TOKENS_PER_CHAR = 1
```

- [ ] **Step 5: Document the calibration run**

Create `docs/SPRINT-46-CALIBRATION-RUN.md` with the 10 tasks, their measured token counts, the medians, and the chosen constants. Format:

```markdown
# Sprint 46 — cost-estimate calibration

**Date:** 2026-05-21  (or actual date when run)
**Sample size:** 10 tasks

## Raw data

| Task # | Description | Model | Prompt | Completion |
|---|---|---|---:|---:|
| 1 | reverse string | llama-3.3 | 750 | 200 |
| ... | ... | ... | ... | ... |

## Per-model medians

| Model | Prompt | Completion |
|---|---:|---:|
| llama-3.3-70b | 800 | 250 |
| kimi-k2.6 | 3500 | 700 |

## Chosen constants

DEFAULT_PROMPT_TOKENS = 2500
DEFAULT_COMPLETION_TOKENS = 600
... (etc)
```

Fill in actual values; the placeholders above are examples.

- [ ] **Step 6: Run cost estimate tests with new constants**

```bash
cd services/orchestrator && uv run pytest tests/test_cost_estimate.py -v
```

Expected: all PASS (tests are inequality-based, calibration doesn't break them).

- [ ] **Step 7: Commit**

```bash
git add services/orchestrator/tally_orchestrator/cost_estimate.py docs/SPRINT-46-CALIBRATION-RUN.md
git commit -m "[s46] cost_estimate: calibrate constants from 10 sample tasks"
```

### Task C4: Build tally-orch:v26 + push to GHCR

**Files:**
- Verify: `services/orchestrator/Dockerfile` exists and builds against the current code

- [ ] **Step 1: Verify the Dockerfile location + LABEL**

```bash
ls services/orchestrator/Dockerfile && grep -nE "LABEL|org.opencontainers" services/orchestrator/Dockerfile
```

If the `org.opencontainers.image.source` label is missing, add it (per the `feedback_ghcr_image_source_label` memory):

```dockerfile
LABEL org.opencontainers.image.source=https://github.com/nicholasraimbault/tally-coding
LABEL org.opencontainers.image.version=v26
```

- [ ] **Step 2: Build the image**

```bash
cd services/orchestrator && docker build -t ghcr.io/nicholasraimbault/tally-orch:v26 .
```

Expected: build succeeds, ~3-5 minutes.

- [ ] **Step 3: Smoke test the image locally**

```bash
docker run --rm -e TALLY_BEARER_TOKEN=smoke -e TALLY_DB_PATH=/tmp/smoke.db \
  -e TALLY_REDPILL_KEY="" -e TALLY_TEST_MODE=1 -p 8118:8118 \
  ghcr.io/nicholasraimbault/tally-orch:v26 &
sleep 8
curl -s -H "Authorization: Bearer smoke" http://localhost:8118/billing/credits | jq .
docker stop $(docker ps -q --filter ancestor=ghcr.io/nicholasraimbault/tally-orch:v26)
```

Expected: returns 200 JSON. (`available_credits` will be 10**8 — admin user defaults to `unlimited`).

- [ ] **Step 4: Push to GHCR**

```bash
echo "$GHCR_PAT" | docker login ghcr.io -u nicholasraimbault --password-stdin
docker push ghcr.io/nicholasraimbault/tally-orch:v26
```

Expected: push succeeds; image visible at https://github.com/nicholasraimbault?tab=packages.

- [ ] **Step 5: Verify visibility (no LABEL = no auto-public — see memory)**

```bash
curl -sI https://ghcr.io/v2/nicholasraimbault/tally-orch/manifests/v26 | head -5
```

Expected: 200 OK with a valid manifest, accessible without auth. If 401, the LABEL didn't take — re-build with LABEL fixed.

- [ ] **Step 6: Commit Dockerfile changes if any**

```bash
git add services/orchestrator/Dockerfile
git commit -m "[s46] Dockerfile: bump version label to v26 + GHCR source label"
```

### Task C5: Deploy `tally-orch:v26` to Phala CVM + live smoke

**Files:**
- Modify: Phala compose file (location per `CLAUDE.local.md`)

- [ ] **Step 1: Bump image tag in compose file**

In the Phala compose file (path in `CLAUDE.local.md`), change `image: ghcr.io/nicholasraimbault/tally-orch:v25` → `:v26`. Confirm Stripe environment variables are set:

- `STRIPE_SECRET_KEY` — restricted key from Clerk dashboard (path #1 per spec)
- `STRIPE_WEBHOOK_SECRET` — endpoint secret from Stripe dashboard for `/webhooks/stripe`

If not configured yet, run the resolution path now (see "Pre-implementation gate" at top of plan).

- [ ] **Step 2: Roll the CVM**

```bash
# Exact command per CLAUDE.local.md
phala deploy --cvm-id tally-orch-prod --compose path/to/compose.yml
```

Expected: ~60s rolling update; new container starts, old container stops; service uptime preserved.

- [ ] **Step 3: Verify the new version is live**

```bash
curl -s https://tally.pronoic.dev/health | jq .
# Look for an `orchestrator_version` field or any tell-tale of v26.
```

Expected: 200 OK.

- [ ] **Step 4: Configure Stripe webhook endpoint**

In the Stripe dashboard, add a webhook endpoint:

- URL: `https://tally.pronoic.dev/webhooks/stripe`
- Events: `checkout.session.completed`, `setup_intent.succeeded`, `payment_intent.succeeded`, `payment_intent.payment_failed`

Save the endpoint secret → set as `STRIPE_WEBHOOK_SECRET` in compose → re-deploy.

- [ ] **Step 5: Live smoke tests**

```bash
# 1. Credits endpoint
curl -s -H "Authorization: Bearer $TALLY_BEARER" https://tally.pronoic.dev/billing/credits | jq .

# 2. Submit a tiny task to verify credit gate doesn't 402 the admin user
curl -sX POST -H "Authorization: Bearer $TALLY_BEARER" -H "content-type: application/json" \
  -d '{"description":"print hello world in python"}' \
  https://tally.pronoic.dev/tasks | jq .

# 3. Set a low cap, submit a task that exceeds estimated cost → expect 402
curl -sX PATCH -H "Authorization: Bearer $TALLY_BEARER" -H "content-type: application/json" \
  -d '{"per_task_cap_credits": 1}' https://tally.pronoic.dev/billing/caps
curl -sX POST -H "Authorization: Bearer $TALLY_BEARER" -H "content-type: application/json" \
  -d '{"description":"build a full SaaS platform with auth, billing, mobile apps, and a recommendation engine"}' \
  https://tally.pronoic.dev/tasks
# Expect: 402 with error=task_cap_estimated_exceeds
# Restore cap
curl -sX PATCH -H "Authorization: Bearer $TALLY_BEARER" -H "content-type: application/json" \
  -d '{"per_task_cap_credits": 10000000}' https://tally.pronoic.dev/billing/caps

# 4. WebSocket smoke (using wscat or curl --include for headers)
wscat -c "wss://tally.pronoic.dev/ws/notifications?token=$TALLY_BEARER" --execute '{"type":"ping"}'
# Expect: receive {"type":"hello"} then {"type":"pong"}

# 5. Create a push device + notification rule, verify they persist
curl -sX POST -H "Authorization: Bearer $TALLY_BEARER" -H "content-type: application/json" \
  -d '{"provider":"desktop_local","label":"smoke"}' https://tally.pronoic.dev/push/devices
curl -sX POST -H "Authorization: Bearer $TALLY_BEARER" -H "content-type: application/json" \
  -d '{"kind":"period_pct","threshold":80}' https://tally.pronoic.dev/notification_rules
curl -s -H "Authorization: Bearer $TALLY_BEARER" https://tally.pronoic.dev/push/devices | jq .
curl -s -H "Authorization: Bearer $TALLY_BEARER" https://tally.pronoic.dev/notification_rules | jq .
```

Expected: all 200 OK, response shapes match Phase A test assertions.

- [ ] **Step 6: Build Flutter Linux + APK against live orchestrator**

```bash
cd tally_coding_app
flutter build linux --release
flutter build apk --release  # plain APK for sideload (F-Droid build is a separate sub-pipeline)
```

Expected: builds succeed.

- [ ] **Step 7: Tag the deploy**

```bash
git tag s46-deployed-v26
git push origin s46-deployed-v26
```

### Task C6: Sprint completion doc

**Files:**
- Create: `docs/SPRINT-46-COMPLETE.md`

- [ ] **Step 1: Write the sprint completion log**

```markdown
# Sprint 46 — Credit-based pricing + privacy-respecting push notifications

**Status:** Complete
**Dates:** 2026-05-20 (spec) → 2026-05-?? (ship)
**Effort:** ~37 hours of focused dev
**Image:** `tally-orch:v26`

## What shipped

### Credit-based pricing
- Replaced flat task-count tiers with credit-based pricing
- 1 credit = $0.01 COGS internal; beta plans at 1.5× markup;
  overage at 2× markup ($0.02/credit)
- Beta tiers: Free $0 / Pro $15 / Max $75 / Ultra $150
- Beta SKUs grandfather forever; stable launch raises prices for new
  customers only
- 7 enforcement checkpoints (pre-submit credit gate, daily/weekly cap,
  architect model allowlist, pre-dispatch estimate, mid-run per-task
  cap, mid-run period cap + auto-recharge, notification rule eval)

### Four overage modes
- Subscription only (default)
- Pre-paid manual
- Pre-paid + auto-recharge with monthly cap
- Full auto unlimited

### Privacy-respecting push notifications
- UnifiedPush (Android F-Droid + GitHub APK) — RFC 8291 encrypted
  end-to-end via user-chosen distributor
- WebSocket foreground client for live updates
- flutter_local_notifications (Linux desktop libnotify)
- Doorbell pattern everywhere — no content transits push providers
- 0-5s jitter to defeat timing correlation
- User-configurable alert rules (period_pct, daily_amount,
  weekly_amount, per_task_amount, auto_recharge_monthly_pct)

### Flutter UI
- Billing screen overhauled: credit balance widget, buy/auto-recharge
  buttons, mode picker, cap settings
- Composer cost estimate banner with color-coded states
- Task channel live cost ticker
- Cap-abort dialog
- Notifications screen (3 tabs: inbox / rules / devices)

### Docs
- New tally-coding/docs-site (Astro + Starlight)
- Public beta pricing page at https://tally.codes/pricing/

## Deferred (open items)

- iOS / macOS / Windows builds → pre-stable-v1.0
- App Store + Play Store distribution → pre-stable-v1.0
- APNs / FCM integration → pre-stable-v1.0
- Enterprise tier → separate launch
- BYO LLM key → enterprise launch
- Email notifications → on user demand
- Length-bucket padding → when FCM/APNs ships
- WebSocket cover-traffic → follow-up
- Embedded Stripe Elements → sprint 47+
- User-configurable jitter range → later sprint

## References

- Spec: `docs/superpowers/specs/2026-05-20-credit-based-pricing-design.md`
- Plan: `docs/superpowers/plans/2026-05-20-credit-based-pricing.md`
- Calibration: `docs/SPRINT-46-CALIBRATION-RUN.md`
```

- [ ] **Step 2: Commit + push**

```bash
git add docs/SPRINT-46-COMPLETE.md
git commit -m "[s46] sprint completion doc"
git push origin main
```

- [ ] **Step 3: Verify GHCR + docs-site are live**

```bash
curl -sf https://tally.codes/pricing/ | grep "Pro (Beta)" > /dev/null && echo "pricing page LIVE"
curl -sI https://ghcr.io/v2/nicholasraimbault/tally-orch/manifests/v26 | grep "200 OK" && echo "image LIVE"
```

Expected: both confirm.

- [ ] **Step 4: Final sprint summary message**

Post in the project's status doc / Slack / commit footnote:

> S46 shipped. Credit-based pricing live with `tally-orch:v26`. Beta
> tiers locked. Privacy-respecting push notifications via UnifiedPush
> + WebSocket + libnotify. iOS / macOS / Windows / Play Store / App
> Store deferred to pre-stable-v1.0. ~37 hours dev time.

