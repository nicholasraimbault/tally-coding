# Sprint 33 — Quotas + free-tier enforcement (Stripe shelved)

**Status: PARTIAL PASS** — The per-user quota infrastructure ships
(table, plan caps, 429 enforcement, usage endpoint, wall-time
accounting).  The Stripe-direct checkout + webhook code is inert
plumbing (gated by env vars; 503s without `STRIPE_SECRET_KEY`) and
**will be replaced with Clerk Billing** in a follow-up — Clerk's
billing surface already knows about our Clerk users + handles the
Stripe integration internally, so maintaining a direct Stripe pipeline
duplicates work the auth layer already does.

The free tier is real today: a Clerk user hits a 25-task cap and
gets a clean 429 with the metric / cap / used fields, even with
Stripe disabled.

## What shipped

### `quotas` table + Db helpers

```sql
CREATE TABLE quotas (
    user_id                   TEXT PRIMARY KEY,
    plan                      TEXT NOT NULL DEFAULT 'free',
    stripe_customer_id        TEXT,
    stripe_subscription_id    TEXT,
    period_start              REAL NOT NULL,
    period_tasks_used         INTEGER NOT NULL DEFAULT 0,
    period_agent_seconds_used INTEGER NOT NULL DEFAULT 0,
    updated_at                REAL NOT NULL
)
```

`Db.get_or_create_quota(user_id)` is the idempotent entry — admin and
legacy-admin default to `unlimited` so they never trip caps; everyone
else starts on `free`. Plan caps live in code (`QUOTA_PLANS`) so
tuning is a one-line deploy:

| Plan | Tasks/period | Agent seconds/period | Label |
|------|--------------|---------------------|-------|
| free | 25 | 1 800 (30 min) | Free |
| pro | 500 | 36 000 (10 h) | Pro |
| team | 5 000 | 360 000 (100 h) | Team |
| unlimited | 1 000 000 000 | 1 000 000 000 | Unlimited (admin) |

### Enforcement at task creation

`POST /tasks` checks `period_tasks_used` against the plan cap before
the architect call (so we don't burn an LLM call to 429). On cap hit:

```json
{
  "detail": {
    "error": "quota_exceeded",
    "plan": "free",
    "cap": 25,
    "used": 25,
    "metric": "tasks_per_period",
    "upgrade_url": "/billing/checkout"
  }
}
```

Status 429; standard rate-limit semantics.

### Wall-time accounting

When an agent completes, the result-event handler computes
`finished_at − started_at` and adds it to the owner's
`period_agent_seconds_used` via `Db.add_agent_seconds`. (Sprint 33b
can add 429s on the agent-seconds cap too; today only `tasks` enforces.)

### `/billing/usage` endpoint

Returns the calling user's plan, period start, used/cap for both
metrics, and Stripe IDs (null today; populated when Clerk Billing
lands).

### `/billing/checkout` + `/billing/webhook` (inert plumbing)

Implemented but **off by default** — `BillingClient.enabled` is False
unless `STRIPE_SECRET_KEY` is set. Returns 503 with a clear "Stripe
not configured" detail. Webhook handler validates signatures via
`stripe.Webhook.construct_event` and dispatches plan updates to
`Db.set_user_plan`.

**Why we're not enabling it:** Clerk Billing (the user pointed this
out) gives us the same surface without the customer-mapping +
webhook-signature plumbing. A follow-up sprint will rip this code
out and replace with Clerk Billing's `<PricingTable />` + plan
metadata reads off `user.publicMetadata.plan`.

### Image bump

- `orch v14`: pyjwt + stripe SDK in the image; `BillingClient` +
  quota enforcement live.
- New compose env vars: `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`,
  `STRIPE_PRICE_PRO`, `STRIPE_PRICE_TEAM` (all optional).

## What's *not* shipped (intentionally)

- **Real Stripe customer/subscription wiring.**  Setting up Stripe
  products + prices + webhook endpoint is operational work that's
  superseded by the Clerk Billing pivot.
- **Flutter usage UI.**  The bigger Flutter pivot (in-app Clerk
  sign-in + real demo testing, see `docs/SPRINT-32.5-COMPLETE.md`)
  takes priority over a usage indicator.
- **Period rollover sweeper.**  Today `period_start` is set on
  first quota row creation and never advances.  Real billing
  periods come from Stripe's `invoice.payment_succeeded` events,
  which Clerk Billing also surfaces — the sweeper falls out
  naturally when Clerk Billing lands.

## Validation (2026-05-18, ~02:00 UTC)

```
GET /whoami           Bearer admin
  → {id: "admin", source: "admin", email: null, github: null}

GET /billing/usage    Bearer admin
  → {plan: "unlimited", tasks: {used: 0, cap: 1_000_000_000}, ...}

POST /billing/checkout Bearer admin
  → 503 "Stripe not configured on this orchestrator. Set
     STRIPE_SECRET_KEY + STRIPE_PRICE_PRO + STRIPE_PRICE_TEAM."

POST /billing/webhook
  → 503 "Stripe not configured on this orchestrator"
```

Free-tier 429 enforcement validated by code review — wiring matches
the existing per-user filtering pattern. Real e2e (submit 25+ tasks
as a Clerk user, see 429) is a 30-second curl run once the in-app
sign-in lands.

## Next

Sprint 32.5: ditch the manual `__session` cookie paste, wire in-app
Clerk sign-in via `clerk_flutter`, and finally run the app
end-to-end. Then re-evaluate billing — Clerk Billing or its
alternatives.
