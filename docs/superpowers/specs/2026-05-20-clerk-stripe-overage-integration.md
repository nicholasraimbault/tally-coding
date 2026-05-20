# Sprint 46.5 — Clerk + Stripe overage integration

**Status:** Shipped (`tally-orch:v26.2` deployed 2026-05-20)
**Date:** 2026-05-20
**Branch / tag:** `main` / `s46.5-deployed-v26.2`

## Why this exists

Sprint 46 shipped a complete credit-pricing + overage UI but left the
Stripe direct paths gated behind `STRIPE_SECRET_KEY` (unset on
deploy).  The original design assumed Clerk's metered subscription
items API as a fallback if direct Stripe access wasn't available.
Research during this sprint found:

1. **Clerk's metered API doesn't exist yet** (Q2 2026, still
   roadmap).  The fallback path from the Sprint 46 spec isn't
   buildable today.
2. **Clerk Billing supports bring-your-own-Stripe-account** as of
   November 2025.  This is the path we took: a fresh Stripe account
   linked into Clerk, with the resulting `sk_test_…` consumed by
   our existing `stripe_direct.py`.

What ended up being needed wasn't a refactor — it was a fix.  The
original Sprint 46 code targeted the legacy `stripe.Checkout.Session.create`
API; the installed `stripe-python` resolved to 15.1.0 which removed
that surface.  The "design" in this spec is mostly a record of the
two corrections.

## What landed

### Bring-your-own-Stripe linkage

Operator-side (~30 min):

1. Created a fresh Stripe account at `dashboard.stripe.com/register`.
   - Business type: SaaS
   - Website: `tally.pronoic.dev`
   - Bank: test-mode `Test (Non-OAuth)` placeholder
2. Clerk dashboard → Billing → linked the Stripe account.
3. Stripe dashboard → Developers → Webhooks → added endpoint at
   `https://tally.pronoic.dev/webhooks/stripe` with 4 events:
   `checkout.session.completed`, `setup_intent.succeeded`,
   `payment_intent.succeeded`, `payment_intent.payment_failed`.
4. Added `STRIPE_SECRET_KEY` + `STRIPE_WEBHOOK_SECRET` to
   `services/orchestrator/.env.prod` (zenity-prompted; never via
   shell history).
5. `phala deploy --cvm-id app_c3b5481b… --compose docker-compose.yml
   --env .env.prod --wait` rolled the CVM.

### Code patches

Two real defects in `stripe_direct.py` that the Sprint 46 review pipeline
missed because tests mocked the wrong API surface:

**1. Stripe Python 15.x removed the static-class API.** The Sprint 46
code called `stripe.Checkout.Session.create(...)` and
`stripe.PaymentIntent.create(...)`, which don't exist in 15.x.
Migrated to the `StripeClient(...)` pattern:

```python
client = _stripe_client()           # stripe.StripeClient(key)
client.checkout.sessions.create({...})
client.payment_intents.create({...}, options={"idempotency_key": key})
```

`stripe.Webhook.construct_event(...)` is still a static method in
15.x — left unchanged.

**2. `mode="setup"` Checkout requires `currency`.** Stripe 15.x
enforces this; the Sprint 46 spec didn't include it.  Added
`"currency": "usd"` to `create_setup_session`.

### Test patches

`test_create_checkout_session_calls_stripe` was updated to mock
`stripe.StripeClient(...).checkout.sessions.create` instead of the
legacy static path.  All 64 orchestrator tests still pass.

## Verification

End-to-end smoke against `tally.pronoic.dev` (v26.2):

| Endpoint | Before s46.5 | After s46.5 |
|---|---|---|
| `POST /billing/credits/checkout {"credits":500}` | 503 | 200 → real `cs_test_*` URL |
| `POST /billing/credits/checkout {"credits":100}` | 400 (min) | 400 (min) — unchanged |
| `POST /billing/auto-recharge/setup` | 503 | 200 → real `cs_test_*` URL |
| `PATCH /billing/auto-recharge` | 200 (no Stripe needed) | 200 — unchanged |
| `GET /billing/credits` | 200 | 200 — unchanged |

The Stripe Checkout URLs are real and would let a test-mode card
complete payment if loaded in a browser.  Webhook delivery + balance
crediting was not exercised end-to-end yet — see "Known limitations"
below.

## Known limitations

1. **Stripe account capabilities pending.** The fresh Stripe account
   is in `card_payments: inactive` state pending Stripe's automated
   review (the orange "Multiple capabilities paused" banner in the
   dashboard).  Direct API calls work because tally.pronoic.dev's
   actual charge path goes through Checkout Sessions — those create
   pending payment intents that can't be confirmed until capabilities
   activate.  Expected to clear within hours; production requires
   manual identity + bank verification.

2. **Webhook end-to-end NOT yet verified.**  A real test-card
   completion in the Checkout UI would fire `checkout.session.completed`
   → our `/webhooks/stripe` handler → `prepaid_credit_balance` += 500.
   Blocked on point #1 (capabilities pending).  Re-run the smoke
   from `docs/SPRINT-46-DEPLOY-PROCEDURE.md` §"Live smoke tests"
   once capabilities activate.

3. **`stripe_customer_id` not populated for admin user.**  The
   admin user has no Clerk subscription, so `quota.stripe_customer_id`
   is null.  Our `create_credits_checkout_session` handles this by
   omitting the customer parameter (Stripe creates a fresh one).
   But the resulting Customer isn't linked back to the admin user —
   the webhook handler relies on `metadata.user_id` for that.
   Acceptable for admin testing; real paid users go through Clerk
   first which populates `stripe_customer_id` via the existing
   `/webhooks/clerk` handler.

4. **`stripe-python` 15.x deprecation warning.**  The 15.x SDK
   emits a one-time DeprecationWarning that `client.checkout` (top-
   level) is being moved to `client.v1.checkout` in some future
   release.  We're on the supported path for 15.x; switch to
   `.v1.checkout` when the SDK warns it's actually being removed
   (no 16.x ETA at time of writing).

5. **No `customer_email` on Checkout Sessions.**  Stripe Checkout
   prefills the email field when `customer_email` is set in the
   request, improving UX.  Not currently set; users type their
   email on the Checkout page.  Add when the Clerk `user.email` is
   easily available at request time (it's in the JWT claims).

## Follow-up tickets

- [ ] Verify Stripe webhook delivery end-to-end with a test-card
      Checkout completion (post-capability-activation)
- [ ] Confirm Clerk's bring-your-own-Stripe linkage populates
      `quota.stripe_customer_id` correctly on first paid
      subscription via `/webhooks/clerk` handler (no real
      subscribers to test against today)
- [ ] Add `customer_email` from Clerk JWT to Checkout requests
- [ ] Production-mode Stripe activation (bank account, identity,
      tax info) before flipping the orchestrator to live keys
- [ ] Re-deploy as `tally-orch:v26.3` with `customer_email` patch +
      any issues uncovered by webhook verification

## References

- Sprint 46 spec: [`2026-05-20-credit-based-pricing-design.md`](2026-05-20-credit-based-pricing-design.md)
- Sprint 46 plan: [`../plans/2026-05-20-credit-based-pricing.md`](../plans/2026-05-20-credit-based-pricing.md)
- Sprint 46 complete: [`../../SPRINT-46-COMPLETE.md`](../../SPRINT-46-COMPLETE.md)
- Deploy procedure: [`../../SPRINT-46-DEPLOY-PROCEDURE.md`](../../SPRINT-46-DEPLOY-PROCEDURE.md)
- Clerk bring-your-own-Stripe: https://clerk.com/changelog/2025-11-14-clerk-billing-existing-stripe-accounts
- Stripe-Python 15.x migration: https://github.com/stripe/stripe-python/wiki/v1-namespace-in-StripeClient
- Commit: `b2088b3` (s46.5 migration)
- Tag: `s46.5-deployed-v26.2`
