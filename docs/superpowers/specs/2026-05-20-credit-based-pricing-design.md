# Sprint 46 — Credit-based pricing with privacy-respecting push notifications

**Status:** Design (pre-implementation)
**Date:** 2026-05-20
**Sprint number:** S46

## Why this exists

Tally Coding currently uses flat task-count tiers (Free 25 / Pro 500 / Team
5000) with no per-task cost cap. A single hard task with S42 routing
(Kimi + DeepSeek-R1 across 4 agents) costs $0.10-$0.30 of Red Pill
spend; a runaway task can hit $1+. The current tier math is upside-down:
a Pro user maxing out at $0.30/task costs $150 against $20 revenue. **A
single power user could bankrupt the company in a quarter.**

The founder's hard constraint: *"I have no room for spending more than
we make."* Per-user worst-case at max usage must be profitable (or at
worst break-even on Free as marketing spend).

Two adjacent problems land in the same sprint because they share code:

1. **Privacy-respecting push notifications.** Spend alerts, task
   completions, and cost-cap notifications need to reach users
   cross-platform without leaking content through Google FCM, Apple
   APNs, or any third-party push service we don't control. This is a
   product-positioning requirement (the privacy story we already sell)
   as well as a technical requirement (no alternative on de-Googled
   phones).

2. **Cost-aware UX.** Users need to see what they're spending in
   real time, not after the credit balance hits zero. The S39 cost
   dashboard exists but is read-only and reports architect cost only;
   users have no way to feel their spend during a task.

## Goals

- Ship credit-based pricing with per-task cost caps that mathematically
  prevent loss at any usage level.
- Replace task-count caps with credit-of-dollar-cost caps so the unit
  economics survive variable-cost tasks.
- Lock beta-tier prices for users who sign up during beta; new
  customers at stable launch pay higher rates while beta users keep
  their grandfathered rate as long as they don't cancel.
- Surface real-time cost in the Flutter UI (pre-submit estimate,
  live ticker, cap-abort dialog).
- Ship privacy-respecting push notifications via UnifiedPush (Android)
  + WebSocket (foreground) + flutter_local_notifications (desktop).
- All features available at every tier; only thing gated by tier is
  what costs real money (LLM credits + per-task cap + concurrency).

## Non-goals (this sprint)

- iOS App Store distribution → deferred to pre-stable-launch sprint.
- macOS / Windows desktop builds → deferred.
- Google Play Store distribution → deferred.
- APNs / FCM push integrations → deferred to pre-stable-launch.
- Enterprise tier → not exposed during beta.
- BYO LLM key (route through user's own Red Pill / Anthropic / OpenAI
  contract) → deferred to enterprise launch.
- Email notification delivery → deferred (no SendGrid wiring yet).
- Length-bucket padding on push payloads → deferred (only meaningful
  once FCM/APNs ship with encrypted payloads).
- WebSocket cover-traffic dummy messages → deferred.

## Strategic decisions made before design

The full brainstorming session in chat covered:

- **Trigger.dev research** — competitor analysis on Apache 2.0 dev tool
  monetization; informed positioning ("we're not competing with Cursor;
  we're the only TEE-attested multi-agent platform").
- **AI dev tool pricing research** — surveyed Cursor, Devin, Replit,
  v0, Lovable, Anthropic Pro/Max, Trigger.dev. Industry consensus
  post-2025-Cursor-disaster is **credits-as-dollars-of-cost, not
  task-count**; **per-task hard cap is non-negotiable**; **"unlimited"
  language is verboten**.
- **Push notification privacy research** — surveyed Signal, Threema,
  SimpleX, Matrix/Element, Wire, Briar, Olvid. PETS 2024 paper
  (Samarin et al.) found 11/21 messengers leak metadata + 4 leak
  plaintext via FCM. The "doorbell pattern" (empty wake-up + fetch
  over TLS) is the established privacy norm. UnifiedPush mandates RFC
  8291 payload encryption end-to-end, making it structurally more
  private than self-hosted ntfy for users who choose their own
  distributor.

Output of the discussion locked the following:

- **Beta scope:** Android (F-Droid + GitHub APK) + Linux only. No iOS,
  macOS, Windows, Play Store, App Store in this sprint.
- **Beta pricing:** discount stable rates by 25%; lock for life of
  subscription.
- **No Enterprise during beta.**
- **Credits = $0.01 of Red Pill COGS, sold at $0.02 (2× markup).**
  Plan tier pricing reflects markup; overage at same rate.
- **Doorbell push pattern everywhere.** No notification content
  transits push providers; app fetches actual notification from our
  orchestrator over TLS after wake.
- **No self-hosted ntfy.** UnifiedPush accepts arbitrary endpoint URLs
  (user chooses their distributor). WebSocket for foreground;
  flutter_local_notifications for desktop.
- **Four overage modes:** Subscription only / Pre-paid manual /
  Pre-paid + auto with cap / Full auto unlimited.

## Pricing structure

### Tier table (beta — sprint 1 ships these)

| Tier | Beta $/mo | Stable $/mo | Credits | Per-task cap (credits) | Model routing |
|---|---:|---:|---:|---:|---|
| Free | $0 | $0 | 50 ($0.50 COGS) | 25 ($0.25) | llama-3.3-70b only |
| **Pro Beta** | **$15** | $20 | 1,000 ($10 COGS max) | 100 ($1.00) | Full S42 routing |
| **Max Beta** | **$75** | $100 | 5,000 ($50 COGS max) | 500 ($5.00) | Full S42 routing |
| **Ultra Beta** | **$150** | $200 | 10,000 ($100 COGS max) | 1,000 ($10.00) | Full S42 routing |
| Enterprise | not shown | (TBD) | Custom | Custom | Custom + BYO key |

### Margin guarantees

Margin at *max* usage (worst case per user — power-law usage means most
users land at 30% of cap, where margins are much higher):

| Tier | Revenue | LLM COGS | Fixed (Stripe + infra) | Margin at max | Margin at typical (30% usage) |
|---|---:|---:|---:|---:|---:|
| Free | $0 | $0.50 | -- | -$0.50 (CAC) | -$0.15 (CAC) |
| Pro Beta | $15 | $10 | $3 | **$2 (13%)** | ~$9 (60%) |
| Max Beta | $75 | $50 | $5 | **$20 (27%)** | ~$56 (75%) |
| Ultra Beta | $150 | $100 | $5 | **$45 (30%)** | ~$120 (80%) |

Worst-case-at-max is positive on every paid tier. Free is a marketing
cost line: 1-3% conversion to paid covers the CAC per industry
benchmarks (OpenView 2023 dev-tool freemium data).

### Beta price lock

Implementation: two Stripe SKUs per tier (`pro-beta` $15 + `pro-stable`
$20). During beta phase, only `*-beta` SKUs are purchasable via the
Clerk PricingTable. When we flip to stable:

1. Mark `*-beta` SKUs as "no new subscriptions" in Stripe (existing
   subscriptions keep billing at locked rate).
2. PricingTable surfaces only `*-stable` SKUs.
3. Existing beta users see "Pro (Beta) — $15/mo locked" badge in Flutter.
4. Beta user who cancels and re-subscribes gets the stable rate (no
   re-grandfathering).

Clerk + Stripe handle this natively — same pattern Vercel, Linear, etc.
use for grandfathered pricing.

### Credit unit semantics

- **1 credit = $0.01 of Red Pill inference COGS** (internal accounting
  unit). A user's `cost_events.cost_micro_usd` divided by 10,000 gives
  credits used.
- **Included credits in a plan come at a tier-specific effective
  markup.** Pro Beta: $15 plan / 1000 included credits = $0.015 per
  effective included credit. Same effective rate for Max Beta + Ultra
  Beta (1.5× COGS markup baked into beta pricing).
- **Stable tiers will sell included credits at 2× markup** ($0.02
  effective). Beta's 1.5× markup is the 25% beta discount.
- **Overage credits (one-time purchase + auto-recharge) are priced at
  $0.02 per credit user-facing across all tiers** — 2× COGS markup.
  No loyalty discount per-tier; the per-task cap unlock is the reason
  to upgrade, not cheaper credits.

This produces three intentional pressures:

1. **Beta users get a meaningful discount** (1.5× vs 2× markup) that
   stays locked as long as they don't cancel.
2. **Overage is more expensive than included credits even for beta
   users.** Pro Beta included credits cost $0.015 effective; overage
   costs $0.02. Heavy users naturally upgrade tier rather than rely
   on overage.
3. **Stable launch raises new-customer prices to 2× markup**, which is
   industry-standard for AI dev tools. Beta users retain their 1.5×
   markup forever (or until they cancel).

Worked example (Pro Beta):
- Plan price: $15
- Included credits: 1000 (= $10 of COGS max)
- Fixed costs: ~$3 (Stripe + infra)
- Max usage margin: $15 − $10 − $3 = **$2 (13%)**
- Typical usage (~30% of credits): $15 − $3 − $3 = **$9 (60%)**

### Four overage modes

User-configurable per-account, orthogonal to plan tier.

| Mode | Pre-loaded credits | Auto-recharge | Behavior at zero balance |
|---|---|---|---|
| **0. Subscription only** (default) | No | No | Hard stop until next period |
| **1. Pre-paid manual** | Yes (user-bought) | No | Hard stop; user manually tops up |
| **2. Pre-paid + auto-recharge with ceiling** | Yes | Yes, capped $/month | Auto-buy block; stop when monthly cap reached |
| **3. Full auto, unlimited** | No required pre-load | Yes, no cap | Never stops; ad-infinitum billing |

## Data model

### Plan config (in `service.py`, no DB)

```python
QUOTA_PLANS = {
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
        "included_credits": 10**8,
        "default_per_task_cap_credits": 10**8,
        "max_per_task_cap_credits": None,
        "model_allowlist": None,
        "overage_eligible": False,
        "is_beta": False,
    },
}
```

Stable-tier configs (`pro_stable`, `max_stable`, `ultra_stable`,
`enterprise`) are added when transitioning to stable launch; not
present in sprint 1.

### Schema changes — extend `quotas`

```sql
ALTER TABLE quotas ADD COLUMN per_task_cap_credits INTEGER;
ALTER TABLE quotas ADD COLUMN daily_spend_cap_credits INTEGER;
ALTER TABLE quotas ADD COLUMN weekly_spend_cap_credits INTEGER;
ALTER TABLE quotas ADD COLUMN overage_enabled INTEGER NOT NULL DEFAULT 0;
ALTER TABLE quotas ADD COLUMN auto_recharge_mode INTEGER NOT NULL DEFAULT 0;  -- 0|1|2|3
ALTER TABLE quotas ADD COLUMN auto_recharge_block_credits INTEGER NOT NULL DEFAULT 500;
ALTER TABLE quotas ADD COLUMN auto_recharge_monthly_cap_micro_usd INTEGER;
ALTER TABLE quotas ADD COLUMN auto_recharge_spent_this_month_micro_usd INTEGER NOT NULL DEFAULT 0;
ALTER TABLE quotas ADD COLUMN stripe_payment_method_id TEXT;
ALTER TABLE quotas ADD COLUMN prepaid_credit_balance INTEGER NOT NULL DEFAULT 0;
ALTER TABLE quotas ADD COLUMN spend_alert_threshold_pct INTEGER NOT NULL DEFAULT 80;
ALTER TABLE quotas ADD COLUMN alert_80_sent_at REAL;
ALTER TABLE quotas ADD COLUMN alert_100_sent_at REAL;
```

### Schema changes — new tables

```sql
CREATE TABLE IF NOT EXISTS overage_purchases (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    ts REAL NOT NULL,
    credits_purchased INTEGER NOT NULL,
    cost_charged_micro_usd INTEGER NOT NULL,
    kind TEXT NOT NULL,            -- 'one_time' | 'auto_recharge'
    stripe_payment_intent_id TEXT,
    status TEXT NOT NULL DEFAULT 'pending',
    failure_reason TEXT
);
CREATE INDEX idx_overage_user_ts ON overage_purchases(user_id, ts DESC);

CREATE TABLE IF NOT EXISTS notification_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    threshold INTEGER NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    last_fired_at REAL,
    created_at REAL NOT NULL
);
CREATE INDEX idx_notif_rules_user ON notification_rules(user_id, enabled);

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
CREATE INDEX idx_notifications_user ON notifications(user_id, dismissed_at, created_at DESC);

CREATE TABLE IF NOT EXISTS push_devices (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    provider TEXT NOT NULL,        -- 'unifiedpush' | 'desktop_local'
    endpoint_url TEXT,             -- for unifiedpush
    label TEXT,
    platform TEXT,
    enabled INTEGER NOT NULL DEFAULT 1,
    last_seen_at REAL,
    created_at REAL NOT NULL
);
CREATE INDEX idx_push_devices_user ON push_devices(user_id, enabled);
```

### Derived state (no new columns)

- `credits_used_this_period` = `SUM(cost_events.cost_micro_usd) / 10_000 WHERE user_id=? AND ts >= period_start`
- `credits_available` = `(plan.included_credits − credits_used_this_period) + prepaid_credit_balance`
- `effective_per_task_cap_credits` = `COALESCE(quotas.per_task_cap_credits, plan.default_per_task_cap_credits)`

Decision: derive credit-used from `cost_events` rather than
denormalize into `quotas`. Reasons: single source of truth; SUM is
sub-millisecond at scale; cost-capture has three insertion paths
(architect, agents, future BYO) so denormalization invites drift.

## Cost enforcement pipeline

### Checkpoints (sequential across task lifecycle)

| # | Checkpoint | Trigger | Failure response |
|---|---|---|---|
| 1 | Pre-submit credit gate | POST /tasks | 402 `no_credits_remaining` |
| 2 | Daily/weekly cap | POST /tasks | 402 `daily_cap_reached` / `weekly_cap_reached` |
| 3 | Architect model override | Architect call | Silent — overrides architect's premium picks |
| 4 | Per-task estimated-cost pre-check | After architect, before dispatch | Re-route to cheap models; if still over, abort with `task_cap_estimated_exceeds` |
| 5 | Mid-run per-task cap abort | After each agent completes | Abort remaining stages; status `aborted_cost_cap` |
| 6 | Mid-run period cap auto-handling | After each agent's cost event | Trigger auto-recharge OR abort with `period_cap_reached` |
| 7 | Alert threshold check | After each cost event | Push notification; mark `alert_80_sent_at` / `alert_100_sent_at` |

### Pre-submit credit gate (Checkpoint 1)

```python
async def check_credit_balance(user: ClerkUser, db: Db) -> None:
    plan = QUOTA_PLANS[user.plan]
    period_start = db.get_quota(user.id)["period_start"]
    used = db.credits_used_this_period(user.id, period_start)
    prepaid = db.get_quota(user.id)["prepaid_credit_balance"]
    available = plan["included_credits"] - used + prepaid
    if available > 0:
        return
    mode = db.get_quota(user.id)["auto_recharge_mode"]
    if mode == 3:
        await trigger_auto_recharge_unlimited(user.id)
        return
    if mode == 2 and db.auto_recharge_under_monthly_cap(user.id):
        await trigger_auto_recharge_capped(user.id)
        return
    raise HTTPException(402, detail={"error": "no_credits_remaining", ...})
```

### Mid-run per-task cap (Checkpoint 5)

After each agent result lands in the orchestrator:

```python
task_cost_so_far_credits = db.task_cost(task_id)["total_micro_usd"] // 10_000
effective_cap = db.effective_per_task_cap_credits(task["user_id"])
if task_cost_so_far_credits > effective_cap:
    self.db.mark_failed(task_id, f"cost cap reached: {task_cost_so_far} > {effective_cap}")
    self._task_artifacts.pop(task_id, None)
    await self._publish_status(task_id, "aborted_cost_cap", {
        "cost_credits": task_cost_so_far_credits,
        "cap_credits": effective_cap,
    })
```

S41's task_artifacts retention rule applies — partial artifacts
preserved on cap-abort (same as deliberate stop).

### Mode 3 + Stripe outage

If user is Mode 3 and Stripe's API is down, `trigger_auto_recharge_unlimited`
catches the exception and returns 503 with `auto_recharge_payment_failed` +
"Stripe unreachable, retry shortly." Task is not dispatched. **No credit
debt is ever created.** This is the literal "never spend more than we
make" rule.

## Stripe billing flow

### Three distinct flows

1. **Plan tier subscription** (existing; Clerk Billing manages end-to-end).
   No changes in this sprint beyond adding beta SKUs.

2. **One-time credit purchase (Mode 1)**:
   - Flutter `POST /billing/credits/checkout?credits=N`
   - Orchestrator creates Stripe Checkout Session, returns URL
   - User completes payment in browser
   - Webhook `checkout.session.completed` → orchestrator credits
     `prepaid_credit_balance`, marks `overage_purchases` row succeeded

3. **Auto-recharge (Modes 2 + 3)**:
   - **Setup phase:** Flutter `POST /billing/auto-recharge/setup` →
     orchestrator creates Stripe Checkout Session in `setup` mode (saves
     card without charging) → user completes in browser → webhook
     `setup_intent.succeeded` → store `stripe_payment_method_id` → user
     picks block size + monthly cap in Flutter UI
   - **Trigger phase:** When credit_check fails with overage enabled,
     orchestrator calls `stripe.PaymentIntent.create(off_session=True,
     confirm=True, idempotency_key=...)` → webhook
     `payment_intent.succeeded` → credits added; `payment_intent.payment_failed`
     → disable auto-recharge + push notification

### Idempotency

`PaymentIntent.create` uses `idempotency_key = f"recharge_{user_id}_{period_start}_{already_spent}"`.
Stripe rejects duplicate calls with same key but different params. The
webhook handler uses INSERT OR IGNORE on `overage_purchases.stripe_payment_intent_id`
to deduplicate webhook retries.

### Stripe access path

**Open at time of writing this spec; resolved before implementation
starts:**

Clerk Billing wraps Stripe. We need a Stripe `secret_key` for our own
direct API calls (Checkout Sessions, off-session PaymentIntents).

Resolution path:
1. **Preferred:** Clerk's dashboard exposes the underlying Stripe
   account; we generate a restricted `sk_` key with scopes
   (`charges:write`, `payment_intents:write`, `checkout_sessions:write`,
   `customers:read`, `payment_methods:read`).
2. **Fallback:** Use Clerk Billing's "metered subscription items" API
   (if it exists) for usage-based charges. Slightly worse UX (charges
   land on next subscription invoice rather than immediately) but no
   separate Stripe access needed.

Action item before implementation: verify path #1 in Clerk dashboard.

### Stripe pricing knobs

- 1 credit = $0.02 user-facing (2¢)
- Minimum one-time purchase: $5 (250 credits) — below this, Stripe's
  $0.30 fixed fee eats too much of the charge
- Default auto-recharge block sizes:
  - Pro: 500 credits ($10)
  - Max: 1000 credits ($20)
  - Ultra: 2500 credits ($50)
- Minimum auto-recharge block: $5 (250 credits)

## Push notifications

### Doorbell pattern (privacy contract)

Push payloads never contain notification content. The orchestrator's
push helper sends only:

- An empty signal to UnifiedPush endpoints (with RFC 8291 payload
  encryption applied by the distributor)
- A WebSocket frame `{"type": "new_notification", "id": int}` over
  authenticated TLS to the Flutter client
- A native OS notification via `flutter_local_notifications` (desktop;
  rendered locally, no transit)

In all cases, the app receives a wake-up signal and then `GET /notifications`
over authenticated TLS to fetch the actual content. The push provider
never sees notification content.

### Jitter

Server adds `random.uniform(0, 5)` second delay before invoking
`fan_out_push()` to defeat timing-correlation attacks (Kollmann/Beresford
2017, Push Attack 2018). User-tunable in settings (later sprint;
default 0-5s in sprint 1).

### Push provider matrix (sprint 1)

| Platform | Build | Channel | Privacy notes |
|---|---|---|---|
| Android | F-Droid + GitHub APK | UnifiedPush (user picks distributor) | RFC 8291 encrypted end-to-end |
| Linux desktop | direct binary | WebSocket (foreground) + libnotify (native OS) | Local only when desktop; no third party |
| iOS | (not shipping in sprint 1) | n/a | n/a |
| macOS / Windows | (not shipping in sprint 1) | n/a | n/a |

Sprint pre-stable-v1.0 (later) layers in:
- APNs + FCM with empty doorbell payloads
- Build flavor system if Play Store + F-Droid require it

### Notification rules (kinds)

| Kind | Threshold semantics | Reset trigger |
|---|---|---|
| `period_pct` | % of monthly subscription pool (e.g. 80) | Subscription period rollover (S44 sweeper) |
| `daily_amount` | Credits/day | UTC midnight |
| `weekly_amount` | Credits/week | UTC Monday 00:00 |
| `per_task_amount` | Credits per single task | Per-task (fires once per task) |
| `auto_recharge_monthly_pct` | % of `auto_recharge_monthly_cap` | Subscription period rollover |

Default rules seeded on first paid-plan upgrade: `period_pct=80` and
`period_pct=100`.

Mode 3 users get no default rules + a soft nudge: *"Mode 3 has no
spending cap. Add daily/weekly notifications to monitor usage."*

### Notification delivery

```python
async def fan_out_push(user_id: str, notification: dict) -> None:
    # 1. Authoritative store
    notification_id = db.insert_notification(user_id, notification)
    # 2. Jitter (privacy)
    await asyncio.sleep(random.uniform(0, 5))
    # 3. WebSocket broadcast to active clients
    for ws in active_websockets_for_user(user_id):
        await ws.send_json({"type": "new_notification", "id": notification_id})
    # 4. Wake-up signal to enrolled devices without active WS
    for device in db.list_enrolled_devices(user_id):
        if device_has_active_websocket(device):
            continue
        match device.provider:
            case "unifiedpush":
                # Empty POST to user's distributor endpoint
                await httpx.post(device.endpoint_url, content=b"")
            case "desktop_local":
                # Notification is local — desktop app polls
                # /notifications on a timer or via WS; nothing to send
                pass
```

## Flutter UI

### 4a — Billing screen (replaces existing /billing surface)

Single scroll page with sections in this order:

1. Plan badge ("Pro (Beta) — $15/mo locked") + period countdown
2. Credit balance widget (total = subscription + prepaid; progress bar)
3. "Buy credits" + "Set up auto-recharge" buttons
4. Auto-recharge configuration (mode picker, block size, monthly cap, saved card)
5. Spend caps (per-task, daily, weekly)
6. Notifications summary + link to dedicated screen
7. Cost dashboard (existing S39 panel, moved down)

### 4b — Composer cost estimate (#general)

Above the text input, banner showing `Estimated cost: N credits ($X.XX)`
that updates as user types (debounced 500ms). Heuristic based on
description length + complexity keywords; consults `AGENT_COST_ESTIMATE_CREDITS`.

Below the banner: `N credits remaining this period`.

Color-coded:
- Green: estimate < 50% of available
- Orange: estimate exceeds per-task cap (cheaper models will be used)
- Red: estimate > available (may abort mid-run)

Submit button stays enabled (soft warning; not a hard block).

### 4c — Task channel live cost ticker

Header chip showing `💰 N credits ($X.XX)`, polls `/tasks/{id}/cost` every
3s while task is running. Color-coded against per-task cap.

Cap-abort dialog when task ends with `aborted_cost_cap`:
- Headline + cap explanation
- List of agents that completed vs skipped
- "View partial artifacts" + "Raise cap & retry" actions

### 4d — Notifications screen

Reached from billing screen + rail.

Three sections:
1. Push devices (list + add)
2. Alert rules (list + add + edit)
3. Recent notifications inbox (paginated, dismiss/mark-all-read)

Push device add flow:
- Android: opens UnifiedPush distributor picker (uses `unifiedpush` plugin); first-launch flow if no distributor installed prompts to install ntfy from F-Droid or other distributors
- Desktop: requests OS notification permission via `flutter_local_notifications`
- iOS: shows "iOS push requires the App Store version (coming with v1.0)" + WebSocket-only fallback explanation

### 4e — Public pricing page (docs-site, Astro/Starlight)

Static page on docs-site (not Flutter):
- Hero with privacy-first positioning
- Tier comparison table (Free + Pro Beta + Max Beta + Ultra Beta)
- "How credits work" explainer
- FAQ
- No Enterprise tier shown during beta

## REST + WebSocket API additions

### New endpoints

| Verb / Path | Purpose | Auth |
|---|---|---|
| `GET /billing/credits` | Current credit balance + breakdown | Clerk JWT |
| `POST /billing/credits/checkout` | Mint Stripe Checkout for one-time purchase | Clerk JWT |
| `POST /billing/auto-recharge/setup` | Mint Stripe Checkout for card setup | Clerk JWT |
| `PATCH /billing/auto-recharge` | Update mode/block/cap | Clerk JWT |
| `GET /billing/caps` | Current per-task/daily/weekly caps | Clerk JWT |
| `PATCH /billing/caps` | Update caps | Clerk JWT |
| `GET /notifications` | List notifications (paginated, since-id) | Clerk JWT |
| `POST /notifications/{id}/dismiss` | Mark notification read | Clerk JWT |
| `GET /notification_rules` | List rules | Clerk JWT |
| `POST /notification_rules` | Create rule | Clerk JWT |
| `PATCH /notification_rules/{id}` | Update rule | Clerk JWT |
| `DELETE /notification_rules/{id}` | Delete rule | Clerk JWT |
| `GET /push/devices` | List enrolled devices | Clerk JWT |
| `POST /push/devices` | Enroll device (UnifiedPush endpoint URL or desktop_local) | Clerk JWT |
| `DELETE /push/devices/{id}` | Revoke device | Clerk JWT |
| `POST /webhooks/stripe` | Stripe events | Stripe signature |

### New WebSocket endpoint

`GET /ws/notifications` — long-lived, authenticated via Clerk JWT in
the upgrade request. Server pushes `{"type": "new_notification", "id": int}`
frames. Client fetches actual content via REST. Reconnect with
exponential backoff on disconnect.

## Migration

Existing state (today's `tally-orch:v25`):
- 22 lifetime tasks in production, all admin-owned
- `quotas.period_tasks_used` + `period_agent_seconds_used` — denormalized
  counters; retained but no longer enforcement-relevant
- `cost_events` table — already source of truth for credit usage

Steps:

1. Schema migration runs on orchestrator boot. Additive ALTER TABLEs +
   new tables; all idempotent + safe.
2. Existing admin user automatically remains `unlimited` plan.
3. No data backfill needed; `cost_events` is already the truth.
4. Existing `/billing/usage` + `/billing/cost` endpoints stay
   backwards-compatible; new `/billing/credits` added alongside.

## Testing strategy

1. **Unit tests** (pytest):
   - `cost.py`: estimate_task_cost_credits across team_specs
   - Credit math (all four overage modes)
   - Notification rule evaluation
   - Stripe webhook signature verification (mocked)

2. **Live smoke** (against `tally.pronoic.dev` after deploy):
   - Submit task → cost recorded → /billing/credits updates
   - Set low per-task cap → submit → verify mid-run abort
   - Enable auto-recharge with Stripe test key → exhaust credits →
     verify recharge fires
   - Configure notification rule → trigger → verify push fires

3. **Worker usage_tokens calibration** (post-deploy):
   - Update worker code to emit `usage_tokens` + `model`
   - Run 10 sample tasks (2 simple llama + 4 medium + 4 hard premium)
   - Compute medians; update `AGENT_COST_ESTIMATE_CREDITS` constant
   - Ship v26.1 with calibrated estimates

## Rollout

No feature flags, no canary. Real users = admin only.

Order:
1. Land code on `main` (one or several PRs, decided by writing-plans)
2. Build `tally-orch:v26`, push to GHCR
3. `phala deploy --cvm-id tally-orch-prod` (60s rolling update)
4. Smoke-test all credit / cost paths against live CVM
5. Calibrate `AGENT_COST_ESTIMATE_CREDITS` from sample runs; ship `v26.1`
6. Document in `docs/SPRINT-46-COMPLETE.md`

Rollback path: `phala deploy` with prior `tally-orch:v25` compose. New
columns on `quotas` become unused; old code still works.

## Open items (deferred from this sprint)

1. **Worker `usage_tokens` reporting calibration loop** — sprint 1 ships
   with placeholder estimates; sprint 1.5 (a few hours of work post-
   launch) calibrates from real samples.
2. **APNs + FCM push integrations** — pre-stable-v1.0 sprint, when
   Apple Dev account + Play Console accounts are set up.
3. **iOS + macOS + Windows builds** — pre-stable-v1.0 sprint.
4. **Build flavors decision (one APK vs two)** — pre-stable-v1.0
   sprint, informed by F-Droid policy + real user demand.
5. **Enterprise tier** — separate launch when first inbound enterprise
   lead converts.
6. **BYO LLM key for Enterprise** — separate sprint, tied to
   enterprise launch.
7. **Email notifications** — when there's user demand; needs SendGrid
   or similar wiring.
8. **Length-bucket padding on push payloads** — once FCM/APNs ship with
   encrypted payloads (pre-stable sprint).
9. **WebSocket cover-traffic** — privacy enhancement; punt to follow-up.
10. **Embedded Stripe Elements** (vs hosted Checkout Sessions) — UI
    polish, sprint 47+.
11. **User-configurable jitter range** — sprint 1 ships 0-5s default;
    later sprint exposes the knob.

## Sprint 1 effort estimate

| Area | Hours |
|---|---:|
| Orchestrator: credit math + schema migrations + plan config | 4 |
| Orchestrator: per-task cap enforcement + mid-run abort + model allowlist | 3 |
| Orchestrator: Stripe webhooks + Checkout flow + auto-recharge | 6 |
| Orchestrator: notification rules + push fan-out + WebSocket endpoint | 4 |
| Worker: `usage_tokens` emission in result events | 1 |
| Flutter: Billing screen overhaul (4a) | 5 |
| Flutter: Composer cost estimate + ticker (4b, 4c) | 3 |
| Flutter: Notifications screen + UnifiedPush + desktop native | 5 |
| docs-site: beta pricing page | 2 |
| Sample-task calibration of cost estimates | 2 |
| Sprint completion doc + commit + deploy + smoke | 2 |
| **Total** | **37** |

Roughly 1.5-2 weeks of focused calendar time at single-developer pace.

## References

- Brainstorming research in chat:
  - Trigger.dev positioning + monetization
  - AI dev-tool pricing best practices (Cursor, Devin, Replit, etc.)
  - Push notification privacy (Signal, Threema, SimpleX, PETS 2024)
- Existing sprints this depends on:
  - S33-rest — Clerk Billing integration
  - S39 — cost dashboard, cost_events table
  - S42 — smarter LLM routing (architect model picks)
  - S44 — quota period rollover sweeper
  - S45 — Prometheus metrics + alerts
  - All shipped in `tally-orch:v25`.

---

End of design spec. Implementation plan to follow via `writing-plans` skill.
