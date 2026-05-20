# Sprint 46 — Credit-based pricing + privacy-respecting push notifications

**Status:** Code complete on `feat/sprint-46-credit-pricing`
**Dates:** 2026-05-20 (spec) → 2026-05-20 (ship)
**Effort:** 52 commits, 66 files, +11,948 / -454 lines
**Image:** `tally-orch:v26` (build + deploy operator-driven; see
[`SPRINT-46-DEPLOY-PROCEDURE.md`](SPRINT-46-DEPLOY-PROCEDURE.md))
**Branch tags:** `s46-phase-a-done`, `s46-phase-b-done`

## What shipped

### Credit-based pricing

- Replaced flat task-count tiers with credit-based pricing
  (1 credit = $0.01 of Red Pill COGS internal; 2× user-facing
  markup for overage)
- 5 plan tiers: `free`, `pro_beta` ($15), `max_beta` ($75),
  `ultra_beta` ($150), `unlimited` (admin)
- Beta SKUs grandfather for the life of the subscription; stable
  launch will raise prices for new customers only (parallel Stripe
  SKUs pattern from Vercel/Linear)
- 13 new columns on `quotas` + 4 new tables (`overage_purchases`,
  `notification_rules`, `notifications`, `push_devices`); migration
  is additive + idempotent

### 7 cost-enforcement checkpoints

1. **Pre-submit credit gate** — `POST /tasks` 402 if available_credits ≤ 0
2. **Daily / weekly spend caps** — 402 on rolling window cap hit
3. **Architect model allowlist** — free tier silently overridden to llama-only (incl. Solo Coder fallback path)
4. **Pre-dispatch estimated-cost check** — heuristic reroute to cheap models if over per-task cap; 402 if still over
5. **Mid-run per-task cap abort** — `aborted_cost_cap` status published when cumulative cost crosses cap; artifacts cleaned up to match other abort paths
6. **Mid-run period cap + auto-recharge** — Mode 2/3 trigger off-session PaymentIntent; Mode 0/1 abort with `period_cap_reached`
7. **Notification rule evaluation** — fires on every cost event with per-kind idempotency windows (period_pct resets at billing rollover; daily/weekly reset on their own 24h/7d clocks)

### Four overage modes

- **Mode 0** — Subscription only (default; hard stop at zero)
- **Mode 1** — Pre-paid manual top-up
- **Mode 2** — Pre-paid + auto-recharge with monthly cap (Stripe
  off-session PaymentIntent fires when balance hits zero; returns
  False without charging if cap would be exceeded)
- **Mode 3** — Full auto unlimited (Stripe failures surface as 503;
  never speculative credit)

### Stripe direct integration

- New `stripe_direct.py` module: Checkout Sessions for one-time
  credit purchases + setup mode for card-on-file, off-session
  PaymentIntent for auto-recharge, idempotency-keyed by
  `recharge_{user_id}_{period_start}_{already_spent}`
- INSERT pending row **before** Stripe call so a crash between
  charge and INSERT can't strand a real charge with no local row
- Webhook handler at `POST /webhooks/stripe` with signature
  verification + 4 event types (checkout completed, setup
  succeeded, payment succeeded, payment failed) + idempotency via
  status='pending' guard
- Stripe API errors mapped to 503 (lets clients retry); auth
  failures to 400

### Privacy-respecting push notifications

- **Doorbell pattern everywhere** — push payloads carry only an
  `id`; content fetched over authenticated TLS from
  `GET /notifications`
- **UnifiedPush** for Android (F-Droid + GitHub APK) — RFC 8291
  encrypted end-to-end via user-chosen distributor; no FCM
- **WebSocket** for foreground (`/ws/notifications`) — bearer or
  Clerk JWT auth, hello/ping/pong protocol, exponential reconnect
  backoff (1s → 60s cap)
- **flutter_local_notifications** for Linux desktop (libnotify)
- **0-5s jitter** on fan-out to defeat timing-correlation attacks
- 5 notification rule kinds: period_pct, daily_amount,
  weekly_amount, per_task_amount, auto_recharge_monthly_pct

### Flutter UI

- Billing screen overhaul: `CreditBalanceWidget` (plan badge,
  progress bar, subscription + prepaid breakdown), 4-mode
  auto-recharge picker, block-size + monthly-cap sliders, caps
  configuration
- Composer cost-estimate banner (color-coded against per-task cap
  + available credits)
- Task channel live cost ticker chip (polls `/tasks/{id}/cost`
  every 3s while running)
- Cap-abort dialog ("Raise cap & retry" navigates to billing)
- NotificationsScreen with 3 tabs (inbox / rules / devices)
- UnifiedPushManager + DesktopNotifier service classes
- NotificationsWsClient with reconnect-backoff + doorbell-then-fetch
  pattern wired to signed-in widget lifecycle

### Docs

- New tally-coding/docs-site at `docs-site/` (Astro 6.3 + Starlight
  0.39, BUSL-1.1)
- Public beta pricing page (4-card grid + how credits work + hard
  caps + overage modes + FAQ)
- `SPRINT-46-DEPLOY-PROCEDURE.md` runbook
- `SPRINT-46-CALIBRATION-PROCEDURE.md` runbook for post-launch
  cost-estimate constant tuning

### Test coverage

- **64 orchestrator pytest** tests across 14 test files
- **9 Flutter widget tests** (api, credit_balance, cost_banner,
  cap_dialog, sprint46 deps smoke)
- Live smoke procedure documented for post-deploy

## Notable in-flight fixes (caught by code review during execution)

The subagent-driven workflow surfaced several real bugs that the
spec missed:

- `delete_artifacts` not called on cost-cap abort path (storage
  leak — fixed in A10)
- INSERT-after-charge ordering in `_trigger_off_session_charge`
  (race between successful Stripe charge and local INSERT — fixed
  in A11)
- Daily/weekly notification rule idempotency using `period_start`
  (30-day anchor) instead of the kind-specific window (rules
  fireable only once per month instead of per 24h/week — fixed in
  A14)
- `asyncio.get_event_loop()` inside `asyncio.to_thread` worker
  raises on Python 3.10+ (architect cost recorder's alert hook
  was silently failing — fixed in A16 by capturing the loop in the
  async frame before the thread)
- Architect Solo Coder fallback bypassed the free-tier llama
  allowlist (palette default kimi would have been used; fixed in
  A8 by applying allowlist to the fallback team)
- Client-side credit-estimate unit change (one implementer changed
  1 credit from $0.01 to $0.000001 to make a test pass; reverted
  to preserve user-facing semantics in B5)
- TallyApi subclass vs TallyOrchClient merger (kept single client
  class in B2 instead of fragmenting into two)

## Deferred (open items)

Per the original spec §"Open items" — none of these block beta:

1. **Worker `usage_tokens` re-calibration** — placeholder constants
   work for v26; calibrate post-launch via
   [`SPRINT-46-CALIBRATION-PROCEDURE.md`](SPRINT-46-CALIBRATION-PROCEDURE.md)
2. **APNs + FCM push integrations** — pre-stable-v1.0 sprint
3. **iOS / macOS / Windows builds** — pre-stable-v1.0 sprint
4. **App Store + Play Store distribution** — pre-stable-v1.0 sprint
5. **Build flavors decision (one APK vs two)** — pre-stable-v1.0
6. **Enterprise tier** — separate launch when first inbound lead converts
7. **BYO LLM key for Enterprise** — tied to enterprise launch
8. **Email notifications** — on user demand; needs SendGrid wiring
9. **Length-bucket padding on push payloads** — once FCM/APNs ships
10. **WebSocket cover-traffic** — privacy enhancement; follow-up
11. **Embedded Stripe Elements** (vs hosted Checkout Sessions) —
    UI polish, sprint 47+
12. **User-configurable jitter range** — ships with 0-5s default; UI knob in a later sprint

## Operator next steps

1. Resolve Stripe access path (Clerk dashboard restricted key,
   per [`SPRINT-46-DEPLOY-PROCEDURE.md`](SPRINT-46-DEPLOY-PROCEDURE.md)
   §"Pre-deploy")
2. Build + push `tally-orch:v26` to GHCR
3. Configure Stripe webhook endpoint
4. Update Phala compose with new env vars + image tag
5. Roll the CVM
6. Run live smoke tests
7. Build Flutter Linux + APK for distribution
8. Tag `s46-deployed-v26`
9. Post-launch: run cost-estimate calibration after ~10 paying users

## References

- Spec: [`docs/superpowers/specs/2026-05-20-credit-based-pricing-design.md`](superpowers/specs/2026-05-20-credit-based-pricing-design.md)
- Plan: [`docs/superpowers/plans/2026-05-20-credit-based-pricing.md`](superpowers/plans/2026-05-20-credit-based-pricing.md)
- Deploy procedure: [`SPRINT-46-DEPLOY-PROCEDURE.md`](SPRINT-46-DEPLOY-PROCEDURE.md)
- Calibration procedure: [`SPRINT-46-CALIBRATION-PROCEDURE.md`](SPRINT-46-CALIBRATION-PROCEDURE.md)
- Branch: `feat/sprint-46-credit-pricing`
- Tags: `s46-phase-a-done`, `s46-phase-b-done`
