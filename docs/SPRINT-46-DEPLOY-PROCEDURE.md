# Sprint 46 — Deploy procedure

**Status:** Operator-driven (to be run after merge to `main`)

The Sprint 46 code landed on `feat/sprint-46-credit-pricing`.  This
runbook walks through building, pushing, and deploying
`tally-orch:v26` to the Phala CVM, plus configuring Stripe.

## Prerequisites

- Docker daemon running locally (`systemctl start docker`)
- GHCR personal access token in `$GHCR_PAT` env var, scopes:
  `write:packages`, `read:packages`
- Phala CLI configured (`phala auth status` shows logged-in user)
- Clerk dashboard access to generate a restricted Stripe key
- Stripe dashboard access to configure the webhook endpoint
- The host paths in `CLAUDE.local.md` (private; not in git)

## Pre-deploy: Stripe access path resolution

Before any deploy can succeed, the Stripe access path from the spec
(`docs/superpowers/specs/2026-05-20-credit-based-pricing-design.md`
§"Stripe access path") MUST be resolved.

Preferred path (verify in Clerk dashboard):

1. Open Clerk dashboard → Billing → Stripe integration
2. Confirm there is an option to expose the underlying Stripe
   account or generate a restricted API key
3. If yes, generate a restricted `sk_` key with scopes:
   - `charges:write`
   - `payment_intents:write`
   - `checkout_sessions:write`
   - `customers:read`
   - `payment_methods:read`
4. Set as `STRIPE_SECRET_KEY` in the Phala CVM env

Fallback path (if Clerk doesn't expose direct Stripe access):

1. Use Clerk Billing's "metered subscription items" API for usage
   billing (slightly worse UX — charges land on the next invoice
   rather than immediately)
2. Refactor `stripe_direct.py` to call Clerk's metered API instead
   of Stripe directly (sprint 46.5 deferred follow-up)

## Step 1: Build `tally-orch:v26` locally

```bash
cd ~/Projects/pronoic/tally-coding/services/orchestrator
docker build -t ghcr.io/nicholasraimbault/tally-orch:v26 .
```

Expected: build succeeds in ~3-5 minutes (stage 1 builds skytale-sdk
wheel + Rust; stage 2 is the runtime).

## Step 2: Smoke-test the image locally

```bash
docker run --rm \
  -e TALLY_API_TOKEN=smoke-test \
  -e TALLY_DB_PATH=/tmp/smoke.db \
  -e TALLY_REDPILL_KEY="" \
  -e TALLY_TEST_MODE=1 \
  -p 8080:8080 \
  ghcr.io/nicholasraimbault/tally-orch:v26 &
sleep 8
curl -s -H "Authorization: Bearer smoke-test" \
  http://localhost:8080/billing/credits | jq .
docker stop $(docker ps -q --filter ancestor=ghcr.io/nicholasraimbault/tally-orch:v26)
```

Expected: returns 200 JSON.  `available_credits` will be 10**8
(admin user defaults to `unlimited` plan).

## Step 3: Push to GHCR

```bash
echo "$GHCR_PAT" | docker login ghcr.io -u nicholasraimbault --password-stdin
docker push ghcr.io/nicholasraimbault/tally-orch:v26
```

Expected: push succeeds.

## Step 4: Verify public visibility

```bash
curl -sI https://ghcr.io/v2/nicholasraimbault/tally-orch/manifests/v26 | head -3
```

Expected: `HTTP/2 200`.  If you get `401`, the
`org.opencontainers.image.source` LABEL in the Dockerfile didn't
take — re-check `services/orchestrator/Dockerfile` line 33-35,
rebuild, push.

## Step 5: Configure Stripe webhook endpoint

In the Stripe dashboard:

1. Developers → Webhooks → Add endpoint
2. Endpoint URL: `https://tally.pronoic.dev/webhooks/stripe`
3. Events to listen to (4):
   - `checkout.session.completed`
   - `setup_intent.succeeded`
   - `payment_intent.succeeded`
   - `payment_intent.payment_failed`
4. Add endpoint → copy the signing secret (`whsec_…`)

This secret becomes `STRIPE_WEBHOOK_SECRET` in the Phala CVM env.

## Step 6: Update Phala CVM compose

Update the Phala compose file (path in `CLAUDE.local.md`) with:

- `image: ghcr.io/nicholasraimbault/tally-orch:v26`
- `STRIPE_SECRET_KEY` — restricted key from step §Pre-deploy
- `STRIPE_WEBHOOK_SECRET` — signing secret from step 5

Keep existing env vars (TALLY_API_TOKEN, CLERK_PUBLISHABLE_KEY,
etc.) unchanged.

## Step 7: Roll the CVM

```bash
phala deploy --cvm-id tally-orch-prod --compose path/to/compose.yml
```

Expected: ~60s rolling update; new container starts, old container
stops, no downtime.

## Step 8: Live smoke tests

Replace `$TALLY_BEARER` with the admin bearer token.

```bash
# 1. /billing/credits endpoint
curl -s -H "Authorization: Bearer $TALLY_BEARER" \
  https://tally.pronoic.dev/billing/credits | jq .

# 2. Submit a tiny task — admin's unlimited plan never 402s
curl -sX POST \
  -H "Authorization: Bearer $TALLY_BEARER" \
  -H "content-type: application/json" \
  -d '{"description":"print hello world in python"}' \
  https://tally.pronoic.dev/tasks | jq .

# 3. Cap-exceeded path (set ridiculously low cap, submit huge desc)
curl -sX PATCH \
  -H "Authorization: Bearer $TALLY_BEARER" \
  -H "content-type: application/json" \
  -d '{"per_task_cap_credits": 1}' \
  https://tally.pronoic.dev/billing/caps
curl -sX POST \
  -H "Authorization: Bearer $TALLY_BEARER" \
  -H "content-type: application/json" \
  -d '{"description":"build a full SaaS platform with auth, billing, mobile apps, and a recommendation engine"}' \
  https://tally.pronoic.dev/tasks
# Expect: 402 with error=task_cap_estimated_exceeds
# Restore cap to default
curl -sX PATCH \
  -H "Authorization: Bearer $TALLY_BEARER" \
  -H "content-type: application/json" \
  -d '{"per_task_cap_credits": 10000000}' \
  https://tally.pronoic.dev/billing/caps

# 4. WebSocket smoke (requires wscat — npm install -g wscat)
wscat -c "wss://tally.pronoic.dev/ws/notifications?token=$TALLY_BEARER" \
  --execute '{"type":"ping"}'
# Expect: {"type":"hello",...} then {"type":"pong"}

# 5. Push device + notification rule CRUD
curl -sX POST \
  -H "Authorization: Bearer $TALLY_BEARER" \
  -H "content-type: application/json" \
  -d '{"provider":"desktop_local","label":"smoke"}' \
  https://tally.pronoic.dev/push/devices
curl -sX POST \
  -H "Authorization: Bearer $TALLY_BEARER" \
  -H "content-type: application/json" \
  -d '{"kind":"period_pct","threshold":80}' \
  https://tally.pronoic.dev/notification_rules
curl -s -H "Authorization: Bearer $TALLY_BEARER" \
  https://tally.pronoic.dev/push/devices | jq .
curl -s -H "Authorization: Bearer $TALLY_BEARER" \
  https://tally.pronoic.dev/notification_rules | jq .
```

Expected: all five blocks succeed with the documented response
shapes.

## Step 9: Build Flutter for Linux + Android APK

```bash
cd ~/Projects/pronoic/tally-coding/tally_coding_app
flutter build linux --release
flutter build apk --release
```

Expected: both succeed.  The Linux build appears at
`build/linux/x64/release/bundle/`.  The APK at
`build/app/outputs/flutter-apk/app-release.apk` — sideload-able for
the F-Droid + GitHub APK distribution channels in the beta scope.

## Step 10: Tag the deploy

```bash
cd ~/Projects/pronoic/tally-coding
git tag s46-deployed-v26
git push origin s46-deployed-v26
```

## Rollback procedure (if step 7 or 8 fails)

```bash
# Re-deploy the previous image
phala deploy --cvm-id tally-orch-prod --compose path/to/v25-compose.yml
```

The new columns added to `quotas` by Sprint 46's migration are
additive and idempotent.  The old `tally-orch:v25` image will
silently ignore the new columns and continue to work.  No data
migration backout is needed.

## Post-deploy: calibration

After ~10 paying users have submitted ~50+ tasks each, run the
cost-estimate calibration procedure:
`docs/SPRINT-46-CALIBRATION-PROCEDURE.md`.

## Pre-stable-launch (deferred items)

See `docs/superpowers/specs/2026-05-20-credit-based-pricing-design.md`
§"Open items" for the full list.  Highlights:

- iOS App Store distribution (Apple Dev account needed)
- Google Play Store distribution (Play Console account needed)
- macOS / Windows desktop builds
- APNs + FCM push integrations
- Enterprise tier + BYO LLM keys
- Email notification delivery (SendGrid wiring)
